#!/command/with-contenv bashio
# shellcheck shell=bash
# fxa-db-prepare (oneshot): the bundled MariaDB's data directory, before the server starts,
# with firefox-sync's keep-major guard (db/mysql/keep-major.sh): the pin is in
# /data/firefox-accounts.env as .env has it, FXA_MARIADB_IMAGE=mariadb:<major>. Data of another
# major is refused unless fxa_mariadb_upgrade is on; data of a newer one always. A data
# directory missing while /data/backup has a dump (a restored backup): a new one, the dump
# loaded after the start (fxa-db-bootstrap).
set -eo pipefail
trap 'bashio::log.error "fxa-db-prepare: failed at line ${LINENO}: ${BASH_COMMAND}"' ERR
# shellcheck source=common.sh
. /usr/lib/firefox-accounts/common.sh
fxa_load

if [ "${FXA_DB_CONTAINERS}" != 1 ]; then
  bashio::log.info "The MariaDB add-on holds the accounts' databases: no bundled MariaDB"
  exit 0
fi
server=$(fxa_server_major)
[ -n "${server}" ] || bashio::exit.nok "cannot read the version of the bundled mariadbd"
touch "${FXA_PINS}"
chmod 600 "${FXA_PINS}"
pin=$(fxa_env_get "${FXA_PINS}" FXA_MARIADB_IMAGE)
pinned=${pin#mariadb:}
mkdir -p "${FXA_DATADIR}" /run/mysqld
chown mysql:mysql /run/mysqld
chmod 700 "${FXA_DATADIR}"

if [ ! -d "${FXA_DATADIR}/mysql" ]; then
  bashio::log.info "A new MariaDB ${server} data directory in ${FXA_DATADIR}"
  rm -rf "${FXA_DATADIR:?}"/*
  chown mysql:mysql "${FXA_DATADIR}"
  mariadb-install-db --user=mysql --datadir="${FXA_DATADIR}" --auth-root-authentication-method=socket \
    --skip-test-db > /tmp/mariadb-install-db.log 2>&1 || { cat /tmp/mariadb-install-db.log; bashio::exit.nok "mariadb-install-db failed"; }
  fxa_env_put "${FXA_PINS}" FXA_MARIADB_IMAGE "mariadb:${server}"
  if ls "${FXA_DUMP_DIR}"/firefox-accounts-*.sql.gz > /dev/null 2>&1; then
    bashio::log.warning "No data directory, but a dump in ${FXA_DUMP_DIR}: it is loaded after the start (a restored backup)"
    touch "${FXA_DATADIR}/.fxa-restore-pending"
  fi
  exit 0
fi

data=$(fxa_data_major "${FXA_DATADIR}")
was=${pinned:-${data}}
if [ -z "${pinned}" ] && [ -n "${data}" ]; then
  fxa_env_put "${FXA_PINS}" FXA_MARIADB_IMAGE "mariadb:${data}"
fi
if [ -n "${was}" ] && [ "${was}" != "${server}" ]; then
  if [ "${was}" -gt "${server}" ]; then
    bashio::exit.nok "The data in ${FXA_DATADIR} is MariaDB ${was}, newer than this add-on's MariaDB ${server}: MariaDB cannot go back. Restore a backup taken with MariaDB ${server}, or install the add-on version you had"
  fi
  if [ "${FXA_MARIADB_UPGRADE}" != true ]; then
    bashio::log.error "The data in ${FXA_DATADIR} is MariaDB ${was}, this version of the add-on has MariaDB ${server}."
    bashio::log.error "Not started: the server would upgrade the data to ${server} for good, with no way back but a backup."
    bashio::log.error "To stay on ${was}: install the add-on version you had. To move to ${server}: take a Home Assistant"
    bashio::log.error "backup of this add-on, then turn on fxa_mariadb_upgrade (Configuration, show unused optional options) and start it again."
    exit 1
  fi
  bashio::log.warning "Upgrading the data from MariaDB ${was} to ${server} (fxa_mariadb_upgrade is on)"
  touch "${FXA_DATADIR}/.fxa-upgrade-pending"
fi
chown -R mysql:mysql "${FXA_DATADIR}"
