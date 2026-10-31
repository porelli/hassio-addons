#!/command/with-contenv bashio
# shellcheck shell=bash
# fxa-init (oneshot, first): the options and what the Supervisor says, turned into the stack's
# settings (/run/fxa/fxa.env); the secrets of /data, generated on the first start and never
# again; the link for the Firefox Sync add-on (fxa-link). Fails closed.
set -eo pipefail
trap 'bashio::log.error "fxa-init: failed at line ${LINENO}: ${BASH_COMMAND}"' ERR
# shellcheck source=common.sh
. /usr/lib/firefox-accounts/common.sh

umask 077
mkdir -p /run/fxa /data
chmod 700 /run/fxa
# the options hold the SMTP password, s6's copy of the container's environment the Supervisor's
# token: root's only (bashio and with-contenv read them as root, before a service drops to its user)
[ ! -f /data/options.json ] || chmod 600 /data/options.json
chmod 700 /run/s6/container_environment

# ---- the secrets (prepare_environment.sh's: 32 letters and digits), never replaced: new ones
# would sign everybody out and lock the databases' users out
touch "${FXA_SECRETS}"
chmod 600 "${FXA_SECRETS}"
for name in FXA_AUTH_SECRET FXA_OAUTH_SECRET FXA_PROFILE_SECRET FXA_FLOW_ID_KEY FXA_SESSION_TOKEN_HANDLE_KEY \
  FXA_CONTENT_SESSION_SECRET FXA_MYSQL_PASSWORD FXA_MYSQL_POLICY_PASSWORD FXA_ADMIN_DB_PASSWORD FXA_REDIS_PASSWORD \
  FXA_DB_BOOTSTRAP_PASSWORD FXA_LINK_TOKEN; do
  if [ -z "$(fxa_env_get "${FXA_SECRETS}" "${name}")" ]; then
    fxa_env_put "${FXA_SECRETS}" "${name}" "$(fxa_rand 32)"
    bashio::log.info "Generated ${name} in ${FXA_SECRETS}"
  fi
done
secret() { fxa_env_get "${FXA_SECRETS}" "$1"; }
# opt <option>: its value, empty for an optional one that is not set (bashio says null)
opt() {
  local value
  value=$(bashio::config "$1")
  [ "${value}" != null ] || value=
  printf '%s' "${value}"
}

out=$(mktemp /run/fxa/fxa.env.XXXXXX)
put() { printf '%s=%q\n' "$1" "$2" >> "${out}"; }
url_option() { # url_option <option>: an https URL, without the trailing /
  local value
  value=$(bashio::config "$1")
  value=${value%/}
  case "${value}" in
    https://*) ;;
    http://*) bashio::log.warning "$1 is plain http: Firefox needs https outside of tests" ;;
    *) bashio::exit.nok "$1 must be an https URL, e.g. https://accounts.example.com" ;;
  esac
  printf '%s' "${value}"
}

content=$(url_option fxa_content_url)
auth=$(url_option fxa_auth_url)
profile=$(url_option fxa_profile_url)
sync=$(url_option sync_public_url)
pairing=$(opt fxa_pairing_url)
pairing=${pairing%/}
# the host of FXA_AUTH_URL: the accounts' email domain and the OAuth issuer (compose/fxa.yml)
email_domain=${auth#*://}
email_domain=${email_domain%%/*}
email_domain=${email_domain%%:*}
host=$(hostname)

put FXA_CONTENT_URL "${content}"
put FXA_AUTH_URL "${auth}"
put FXA_PROFILE_URL "${profile}"
put FXA_PAIRING_URL "${pairing}"
put SYNC_PUBLIC_URL "${sync}"
put FXA_EMAIL_DOMAIN "${email_domain}"
put FXA_HOSTNAME "${host}"
for name in FXA_AUTH_SECRET FXA_OAUTH_SECRET FXA_PROFILE_SECRET FXA_FLOW_ID_KEY FXA_SESSION_TOKEN_HANDLE_KEY \
  FXA_CONTENT_SESSION_SECRET FXA_MYSQL_PASSWORD FXA_MYSQL_POLICY_PASSWORD FXA_ADMIN_DB_PASSWORD FXA_REDIS_PASSWORD \
  FXA_LINK_TOKEN; do
  put "${name}" "$(secret "${name}")"
done

# ---- the database: the bundled MariaDB (FXA_DB_CONTAINERS=1) or the MariaDB add-on; on both
# the stack's own users of db/mysql/fxa-mariadb.sql, created by the bootstrap
put FXA_DB mariadb
put FXA_MYSQL_USER fxa
put FXA_MYSQL_POLICY_USER ffs_policy
if bashio::config.true 'fxa_db_containers'; then
  put FXA_DB_CONTAINERS 1
  put FXA_MYSQL_HOST 127.0.0.1
  put FXA_MYSQL_PORT 3306
  # the address the Firefox Sync add-on's admin UI reaches the accounts' database at
  put FXA_DB_PUBLIC_HOST "${host}"
  put FXA_DB_BOOTSTRAP_USER ffs_bootstrap
  put FXA_DB_BOOTSTRAP_PASSWORD "$(secret FXA_DB_BOOTSTRAP_PASSWORD)"
  bashio::log.info "Database: the bundled MariaDB, data in ${FXA_DATADIR}"
else
  if ! bashio::services.available mysql; then
    bashio::exit.nok "fxa_db_containers is off but the Supervisor has no MySQL service: install and start the MariaDB add-on, or turn fxa_db_containers on"
  fi
  db_host=$(bashio::services mysql 'host')
  # its IPv4 address: the add-on network is dual-stack, and the MariaDB add-on's service user
  # exists for 172.30.32.% and 172.30.33.% only (an IPv6 connection is refused, HAOS 18)
  db_ipv4=$(getent ahostsv4 "${db_host}" | awk 'NR == 1 {print $1}')
  [ -z "${db_ipv4}" ] || db_host=${db_ipv4}
  put FXA_DB_CONTAINERS 0
  put FXA_MYSQL_HOST "${db_host}"
  put FXA_MYSQL_PORT "$(bashio::services mysql 'port')"
  put FXA_DB_PUBLIC_HOST "${db_host}"
  put FXA_DB_BOOTSTRAP_USER "$(bashio::services mysql 'username')"
  put FXA_DB_BOOTSTRAP_PASSWORD "$(bashio::services mysql 'password')"
  bashio::log.info "Database: the MariaDB add-on at ${db_host}"
fi
upgrade=false
bashio::config.true 'fxa_mariadb_upgrade' && upgrade=true
put FXA_MARIADB_UPGRADE "${upgrade}"

# ---- email (the sign-up and sign-in codes) and who can sign up
put FXA_SMTP_HOST "$(opt fxa_smtp_host)"
put FXA_SMTP_PORT "$(opt fxa_smtp_port)"
put FXA_SMTP_USER "$(opt fxa_smtp_user)"
put FXA_SMTP_PASS "$(opt fxa_smtp_pass)"
put FXA_SMTP_SECURE "$(opt fxa_smtp_secure)"
put FXA_SMTP_SENDER "$(opt fxa_smtp_sender)"
put FXA_SIGNUPS "$(opt fxa_signups)"
put FXA_SIGNUP_ALLOWLIST "$(opt fxa_signup_allowlist)"
put FXA_MAX_ACCOUNTS initial:unlimited

mv -f "${out}" "${FXA_ENV}"
chmod 600 "${FXA_ENV}"

# ---- the link for the Firefox Sync add-on (accounts: self_hosted): what it needs of these
# accounts, their addresses on the add-on network and the passwords of the admin UI's database
# user and of Redis, served by fxa-link (port 8101) only to the link code's token. Nothing of it
# goes to /share, where every add-on that maps it could read it. The code, <host name>:<token>,
# is printed below for the Firefox Sync add-on's fxa_link_code option
link_dir=/run/fxa-link
mkdir -p "${link_dir}"
link=$(mktemp "${link_dir}/link.env.XXXXXX")
db_host=$(fxa_env_get "${FXA_ENV}" FXA_DB_PUBLIC_HOST)
{
  echo "FXA_OAUTH_SERVER_URL=http://${host}:9000/v1"
  echo "FXA_EMAIL_DOMAIN=${email_domain}"
  echo "FXA_CONTENT_URL=${content}"
  echo "FXA_AUTH_URL=${auth}"
  echo "FXA_PROFILE_URL=${profile}"
  echo "FXA_PAIRING_URL=${pairing}"
  echo "FXA_DB=mariadb"
  echo "FXA_DB_HOST=${db_host}"
  echo "FXA_DB_PORT=$(fxa_env_get "${FXA_ENV}" FXA_MYSQL_PORT)"
  echo "FXA_DB_PASSWORD=$(secret FXA_ADMIN_DB_PASSWORD)"
  echo "FXA_REDIS=${host}:6379"
  echo "FXA_REDIS_PASSWORD=$(secret FXA_REDIS_PASSWORD)"
  echo "FXA_AUTH_UPSTREAM=http://${host}:9000"
  echo "FXA_CONTENT_INTERNAL_URL=http://${host}:3030"
  echo "FXA_PROFILE_INTERNAL_URL=http://${host}:1111"
  [ -z "${pairing}" ] || echo "FXA_PAIRING_INTERNAL_URL=http://${host}:8000"
  echo "FXA_ACCOUNT_EVENTS=false"
  echo "FXA_CLIENT_ADDRESS_DEPTH=2"
  echo "FXA_ACCESS_TOKEN_LIFETIME=60 minutes"
  echo "FXA_SMTP_HOST=$(opt fxa_smtp_host)"
  echo "FXA_SMTP_PORT=$(opt fxa_smtp_port)"
  echo "FXA_SMTP_USER=$(opt fxa_smtp_user)"
  echo "FXA_SMTP_PASS=$(opt fxa_smtp_pass)"
  echo "FXA_SMTP_SECURE=$(opt fxa_smtp_secure)"
  echo "FXA_SMTP_SENDER=$(opt fxa_smtp_sender)"
} > "${link}"
chown -R fxa-link:fxa-link "${link_dir}"
chmod 700 "${link_dir}"
chmod 600 "${link}"
mv -f "${link}" "${link_dir}/link.env"
bashio::log.info "Link code for the Firefox Sync add-on (its option fxa_link_code): ${host}:$(secret FXA_LINK_TOKEN)"
pairing_server=${pairing}
[ -n "${pairing_server}" ] || pairing_server="Mozilla's server"
bashio::log.info "Accounts: ${content} (pages), ${auth} (API), ${profile} (profile), pairing: ${pairing_server}"
