#!/bin/bash
# shellcheck shell=bash
# shellcheck disable=SC2034 # (the settings of the scripts that source it)
# Shared by the add-on's s6 services. The settings keep the stack's names (.env-example of
# firefox-sync, compose/fxa.yml): what the options and the Supervisor say becomes
# /run/fxa/fxa.env, written by fxa-init at every start, read by every service.

FXA_ENV=/run/fxa/fxa.env
# kept across starts, backed up: the generated secrets (never generated again) and the pins
FXA_SECRETS=/data/secrets.env
FXA_PINS=/data/firefox-accounts.env
# the signing keys of the accounts (gen_keys.js & co. write them once), the avatars
FXA_KEYS=/data/fxa-keys
FXA_IMAGES=/data/fxa-profile-images
FXA_DATADIR=/data/mariadb
FXA_DUMP_DIR=/data/backup
FXA_SOCKET=/run/mysqld/mysqld.sock
# SEAM (db-bootstrap): firefox-sync's db/db-setup.sh, copied from the db-bootstrap branch
# until it is merged: the db-bootstrap stage of the Dockerfile, seam/db-bootstrap/SOURCE
DB_SETUP=/usr/share/firefox-accounts/db/db-setup.sh
DB_DIR=/usr/share/firefox-accounts/db
FXA_CONFIG=/usr/share/firefox-accounts/fxa-config
# the accounts' five databases (fixed names, db/mysql/fxa-mariadb.sql)
FXA_DATABASES="fxa fxa_oauth fxa_profile pushbox ffs"

fxa_load() {
  [ -r "${FXA_ENV}" ] || { echo "firefox-accounts: ${FXA_ENV} is missing (fxa-init did not run)" >&2; exit 1; }
  set -a
  # shellcheck disable=SC1090
  . "${FXA_ENV}"
  set +a
}

fxa_rand() {
  python3 -c 'import secrets, string, sys; a = string.ascii_letters + string.digits; print("".join(secrets.choice(a) for _ in range(int(sys.argv[1]))))' "$1" 2> /dev/null ||
    node -e 'const c=require("crypto"),a="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";let s="";while(s.length<+process.argv[1]){const b=c.randomBytes(1)[0];if(b<248)s+=a[b%62]}console.log(s)' "$1"
}

fxa_env_get() {
  { sed -n "s/^$2=//p" "$1" 2> /dev/null || true; } | tail -n 1
}

fxa_env_put() {
  local file=$1 name=$2 value=$3 tmp
  tmp=$(mktemp "${file}.XXXXXX")
  { grep -v "^${name}=" "${file}" 2> /dev/null || true; printf '%s=%s\n' "${name}" "${value}"; } > "${tmp}"
  chmod 600 "${tmp}"
  mv -f "${tmp}" "${file}"
}

fxa_server_major() {
  mariadbd --version 2> /dev/null | sed -n 's/.* Ver \([0-9][0-9]*\)\..*/\1/p'
}
fxa_data_major() {
  { cat "$1/mariadb_upgrade_info" "$1/mysql_upgrade_info" 2> /dev/null || true; } | tr -d '\0' | sed -n '1s/^\([0-9][0-9]*\)\..*/\1/p'
}

fxa_root_sql() {
  mariadb --protocol=socket -S "${FXA_SOCKET}" -u root "$@"
}

# a client of the accounts' server as FXA_MYSQL_USER: MYSQL_PWD, never an argument
fxa_client() {
  local program=$1
  shift
  MYSQL_PWD="${FXA_MYSQL_PASSWORD}" "${program}" --protocol=tcp -h "${FXA_MYSQL_HOST}" -P "${FXA_MYSQL_PORT}" -u "${FXA_MYSQL_USER}" "$@"
}

# the env of a Node.js service of the accounts, as the image's user: PATH and HOME, the
# test CA when there is one (NODE_EXTRA_CA_CERTS, tests only), then the given NAME=value
fxa_node_env() {
  vars=(PATH=/usr/local/bin:/usr/bin:/bin HOME=/home/app)
  [ -z "${NODE_EXTRA_CA_CERTS:-}" ] || vars+=("NODE_EXTRA_CA_CERTS=${NODE_EXTRA_CA_CERTS}")
}

# wait_http <url> [seconds]: until it answers 2xx (the compose healthchecks' depends_on)
fxa_wait_http() {
  local url=$1 deadline=$(( $(date +%s) + ${2:-600} ))
  until curl -sf -o /dev/null "${url}"; do
    [ "$(date +%s)" -lt "${deadline}" ] || return 1
    sleep 2
  done
}
