#!/command/with-contenv bashio
# shellcheck shell=bash
# ffs-init (oneshot, first): the options of the add-on and what the Supervisor says, turned
# into the stack's settings (/run/ffs/sync.env), and the secrets of /data, generated on the
# first start and never again. Fails closed: nothing else starts after an error here.
set -eo pipefail
# an unexpected failure says where, rather than stopping the add-on silently
trap 'bashio::log.error "ffs-init: failed at line ${LINENO}: ${BASH_COMMAND}"' ERR
# shellcheck source=common.sh
. /usr/lib/firefox-sync/common.sh

umask 077
mkdir -p /run/ffs /data
chmod 700 /run/ffs

# ---- the secrets: generated once, 0600, never replaced (a new SYNC_MASTER_SECRET would sign
# every client out; new database passwords would not match the databases)
touch "${FFS_SECRETS}"
chmod 600 "${FFS_SECRETS}"
for pair in SYNC_MASTER_SECRET:64 SYNC_METRICS_HASH_SECRET:32 SYNC_TOKENSERVER_DB_PASSWORD:32 \
  SYNC_STORAGE_DB_PASSWORD:32 ADMIN_DB_PASSWORD:32 ADMIN_METRICS_TOKEN:48 SYNC_DB_BOOTSTRAP_PASSWORD:32; do
  name=${pair%%:*}
  if [ -z "$(ffs_env_get "${FFS_SECRETS}" "${name}")" ]; then
    ffs_env_put "${FFS_SECRETS}" "${name}" "$(ffs_rand "${pair#*:}")"
    bashio::log.info "Generated ${name} in ${FFS_SECRETS}"
  fi
done
secret() { ffs_env_get "${FFS_SECRETS}" "$1"; }

# ---- the options
public_url=$(bashio::config 'sync_public_url')
public_url=${public_url%/}
case "${public_url}" in
  https://*) ;;
  http://*) bashio::log.warning "sync_public_url is plain http: Firefox needs https outside of tests" ;;
  *) bashio::exit.nok "sync_public_url must be the public https URL of the Sync server, e.g. https://sync.example.com" ;;
esac
max_users=$(bashio::config 'sync_max_users')
admin=false
bashio::config.true 'admin' && admin=true
bundled=false
bashio::config.true 'sync_db_containers' && bundled=true
accounts=$(bashio::config 'accounts')
upgrade=false
bashio::config.true 'sync_mariadb_upgrade' && upgrade=true

out=$(mktemp /run/ffs/sync.env.XXXXXX)
put() { printf '%s=%q\n' "$1" "$2" >> "${out}"; }

put FFS_ADMIN "${admin}"
put FFS_MARIADB_UPGRADE "${upgrade}"
put SYNC_PUBLIC_URL "${public_url}"
put SYNC_MAX_USERS "${max_users}"
for name in SYNC_MASTER_SECRET SYNC_METRICS_HASH_SECRET SYNC_TOKENSERVER_DB_PASSWORD SYNC_STORAGE_DB_PASSWORD \
  ADMIN_DB_PASSWORD ADMIN_METRICS_TOKEN; do
  put "${name}" "$(secret "${name}")"
done

# ---- the database: the bundled MariaDB (SYNC_DB_CONTAINERS=1) or the MariaDB add-on, found
# through the Supervisor's services API; on both the stack's own users, created with the
# bootstrap account (SYNC_DB_BOOTSTRAP_USER: the bundled server's own, or the add-on's service user)
put SYNC_DB mariadb
put SYNC_TOKENSERVER_DB_NAME tokenserver
put SYNC_TOKENSERVER_DB_USER tokenserver
put SYNC_STORAGE_DB_NAME syncstorage
put SYNC_STORAGE_DB_USER syncstorage
put ADMIN_DB_NAME ffs_admin
put ADMIN_DB_USER ffs_admin_ui
put ADMIN_DB_SYNC_USER ffs_admin_sync
if [ "${bundled}" = true ]; then
  db_host=127.0.0.1 db_port=3306
  put SYNC_DB_CONTAINERS 1
  put SYNC_DB_BOOTSTRAP_USER ffs_bootstrap
  put SYNC_DB_BOOTSTRAP_PASSWORD "$(secret SYNC_DB_BOOTSTRAP_PASSWORD)"
  bashio::log.info "Database: the bundled MariaDB, data in ${FFS_DATADIR}"
else
  if ! bashio::services.available mysql; then
    bashio::exit.nok "sync_db_containers is off but the Supervisor has no MySQL service: install and start the MariaDB add-on, or turn sync_db_containers on"
  fi
  db_host=$(bashio::services mysql 'host')
  db_port=$(bashio::services mysql 'port')
  # its IPv4 address: the add-on network is dual-stack, and the MariaDB add-on's service user
  # exists for 172.30.32.% and 172.30.33.% only (an IPv6 connection is refused, HAOS 18)
  db_ipv4=$(getent ahostsv4 "${db_host}" | awk 'NR == 1 {print $1}')
  [ -z "${db_ipv4}" ] || db_host=${db_ipv4}
  put SYNC_DB_CONTAINERS 0
  put SYNC_DB_BOOTSTRAP_USER "$(bashio::services mysql 'username')"
  put SYNC_DB_BOOTSTRAP_PASSWORD "$(bashio::services mysql 'password')"
  bashio::log.info "Database: the MariaDB add-on at ${db_host}:${db_port}"
fi
put SYNC_TOKENSERVER_DB_HOST "${db_host}"
put SYNC_TOKENSERVER_DB_PORT "${db_port}"
put SYNC_STORAGE_DB_HOST "${db_host}"
put SYNC_STORAGE_DB_PORT "${db_port}"
put SYNC_DB_TLS_VERIFY true

# ---- the accounts: Mozilla's (the default of .env-example), or the self-hosted add-on's, from
# its link (fxa_link_code). Settings already in the container's environment win
# (tests: a mock FxA)
case "${accounts}" in
  mozilla)
    put FXA_OAUTH_SERVER_URL "${FXA_OAUTH_SERVER_URL:-https://oauth.accounts.firefox.com/v1}"
    put FXA_EMAIL_DOMAIN "${FXA_EMAIL_DOMAIN:-api.accounts.firefox.com}"
    bashio::log.info "Accounts: Mozilla's"
    ;;
  self_hosted)
    # the link code the accounts add-on prints at its start, <its host name>:<token>: the
    # details (its addresses, the passwords of the admin UI's database user and of Redis) come
    # from its link endpoint with that token, over the add-on network; nothing in /share
    code=$(bashio::config 'fxa_link_code')
    [ -n "${code}" ] && [ "${code}" != null ] ||
      bashio::exit.nok "accounts is self_hosted but fxa_link_code is empty: start the \"Mozilla accounts (self-hosted)\" add-on, copy the link code from its log into fxa_link_code"
    link_host=${code%%:*} link_token=${code#*:}
    [[ "${link_host}" =~ ^[a-z0-9][a-z0-9.-]*$ ]] && [ "${#link_token}" -ge 32 ] && [ "${link_host}" != "${code}" ] ||
      bashio::exit.nok "fxa_link_code is not a link code (<host name>:<token>): copy it again from the accounts add-on's log"
    link=$(mktemp /run/ffs/link.XXXXXX)
    status=000
    # (the accounts add-on may still be starting: up to 2 minutes)
    for _ in $(seq 1 60); do
      status=$(curl -s -o "${link}" -w '%{http_code}' --max-time 10 -H @- "http://${link_host}:8101/v1/link" <<< "Authorization: Bearer ${link_token}") || status=000
      [ "${status}" = 000 ] || [ "${status}" = 503 ] || break
      sleep 2
    done
    case "${status}" in
      200) ;;
      401) bashio::exit.nok "the accounts add-on refused fxa_link_code: copy the link code again from its log" ;;
      *) bashio::exit.nok "cannot reach the accounts add-on at ${link_host} (HTTP ${status}): is the \"Mozilla accounts (self-hosted)\" add-on started?" ;;
    esac
    # known names only, one value per line
    while IFS= read -r line || [ -n "${line}" ]; do
      name=${line%%=*} value=${line#*=}
      case "${name}" in
        FXA_OAUTH_SERVER_URL|FXA_EMAIL_DOMAIN|FXA_CONTENT_URL|FXA_AUTH_URL|FXA_PROFILE_URL|FXA_PAIRING_URL|\
        FXA_DB|FXA_DB_HOST|FXA_DB_PORT|FXA_DB_PASSWORD|FXA_REDIS|FXA_REDIS_PASSWORD|FXA_AUTH_UPSTREAM|\
        FXA_CONTENT_INTERNAL_URL|FXA_PROFILE_INTERNAL_URL|FXA_PAIRING_INTERNAL_URL|FXA_ACCOUNT_EVENTS|\
        FXA_CLIENT_ADDRESS_DEPTH|FXA_ACCESS_TOKEN_LIFETIME|FXA_SMTP_HOST|FXA_SMTP_PORT|FXA_SMTP_USER|\
        FXA_SMTP_PASS|FXA_SMTP_SECURE|FXA_SMTP_SENDER)
          put "${name}" "${value}" ;;
      esac
    done < "${link}"
    rm -f "${link}"
    put FFS_ACCOUNTS self_hosted
    bashio::log.info "Accounts: the self-hosted accounts add-on at ${link_host}"
    ;;
  *) bashio::exit.nok "accounts: mozilla or self_hosted, not ${accounts}" ;;
esac

# ---- the admin UI (compose's ffs-admin, profile admin), signed in by Home Assistant: the
# ingress (nginx, port 8099) accepts the Supervisor (172.30.32.2) only and passes its
# X-Remote-User-* headers on from 127.0.0.1, the one trusted proxy. HA's ingress lets in
# administrators only (panel_admin), which the Supervisor sends in X-Remote-User-Groups as
# system-admin: the only group allowed
put ADMIN_AUTH_HEADER X-Remote-User-Name
put ADMIN_AUTH_GROUPS_HEADER X-Remote-User-Groups
put ADMIN_ALLOWED_GROUPS system-admin
put ADMIN_TRUSTED_PROXIES 127.0.0.1/32
put ADMIN_TZ "${TZ:-}"
put FFS_HOSTNAME "$(hostname)"

mv -f "${out}" "${FFS_ENV}"
chmod 600 "${FFS_ENV}"
bashio::log.info "Sync server: ${public_url}, SYNC_MAX_USERS=${max_users}, admin UI: ${admin}"
