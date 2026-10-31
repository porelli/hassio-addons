#!/bin/bash
# shellcheck shell=bash
# shellcheck disable=SC2034 # (the settings of the scripts that source it)
# Shared by the add-on's s6 services. The settings keep the stack's names (.env-example of
# firefox-sync): what the options and the Supervisor say becomes /run/ffs/sync.env, written
# by ffs-init at every start, read by every service.

# where the settings of this start are (root only: passwords)
FFS_ENV=/run/ffs/sync.env
# kept across starts, backed up: the generated secrets (never generated again) and the pins
FFS_SECRETS=/data/secrets.env
FFS_PINS=/data/firefox-sync.env
# the bundled MariaDB's data (left out of the backups, which hold its dump: /data/backup)
FFS_DATADIR=/data/mariadb
FFS_DUMP_DIR=/data/backup
FFS_SOCKET=/run/mysqld/mysqld.sock
# SEAM (db-bootstrap): firefox-sync's db/db-setup.sh, copied from the db-bootstrap branch
# until it is merged: the db-bootstrap stage of the Dockerfile, seam/db-bootstrap/SOURCE
DB_SETUP=/usr/share/firefox-sync/db/db-setup.sh
DB_DIR=/usr/share/firefox-sync/db

ffs_load() {
  [ -r "${FFS_ENV}" ] || { echo "firefox-sync: ${FFS_ENV} is missing (ffs-init did not run)" >&2; exit 1; }
  set -a
  # shellcheck disable=SC1090
  . "${FFS_ENV}"
  set +a
}

# rand <length>: letters and digits, as prepare_environment.sh generates them
ffs_rand() {
  python3 -c 'import secrets, string, sys; a = string.ascii_letters + string.digits; print("".join(secrets.choice(a) for _ in range(int(sys.argv[1]))))' "$1"
}

# env_get <file> <NAME>: the value of NAME=... in an env file written by these scripts
ffs_env_get() {
  { sed -n "s/^$2=//p" "$1" 2> /dev/null || true; } | tail -n 1
}

# env_put <file> <NAME> <value>: set NAME in an env file (0600), replacing it
ffs_env_put() {
  local file=$1 name=$2 value=$3 tmp
  tmp=$(mktemp "${file}.XXXXXX")
  { grep -v "^${name}=" "${file}" 2> /dev/null || true; printf '%s=%s\n' "${name}" "${value}"; } > "${tmp}"
  chmod 600 "${tmp}"
  mv -f "${tmp}" "${file}"
}

# the major of the installed MariaDB server, and of the data in a datadir (what
# mariadb-install-db and mariadb-upgrade wrote), as firefox-sync's db/mysql/keep-major.sh reads them
ffs_server_major() {
  mariadbd --version 2> /dev/null | sed -n 's/.* Ver \([0-9][0-9]*\)\..*/\1/p'
}
ffs_data_major() {
  # (one of the two files only: cat fails on the other)
  { cat "$1/mariadb_upgrade_info" "$1/mysql_upgrade_info" 2> /dev/null || true; } | tr -d '\0' | sed -n '1s/^\([0-9][0-9]*\)\..*/\1/p'
}

# the bundled server, as root over its socket
ffs_root_sql() {
  mariadb --protocol=socket -S "${FFS_SOCKET}" -u root "$@"
}

# a MariaDB client of the Sync databases (dumps): MYSQL_PWD, never an argument
# ffs_sync_client <program> <user> <password> [args]
ffs_sync_client() {
  local program=$1 user=$2 password=$3
  shift 3
  MYSQL_PWD="${password}" "${program}" --protocol=tcp -h "${SYNC_TOKENSERVER_DB_HOST}" -P "${SYNC_TOKENSERVER_DB_PORT}" -u "${user}" "$@"
}
