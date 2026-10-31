#!/command/with-contenv bashio
# shellcheck shell=bash
# ffs-db-prepare (oneshot): the bundled MariaDB's data directory, before the server starts.
#
# The keep-major guard of firefox-sync (db/mysql/keep-major.sh), with the pin in
# /data/firefox-sync.env as .env holds it: SYNC_MARIADB_IMAGE=mariadb:<major>, the major the
# data is on. The image brings the newest long-term MariaDB of when it was built; an update
# of the add-on can bring the next major, which would upgrade the data for good. So on data of
# another major the add-on does not start, unless sync_mariadb_upgrade is on (then the server
# upgrades it, mariadb-upgrade runs, and the pin moves). Data of a newer major than the
# server's is always refused: MariaDB cannot downgrade it.
#
# A data directory missing while /data/backup has a dump (a restore of a Home Assistant
# backup, which leaves the raw files out): a new one, and the dump loaded after the start
# (ffs-db-bootstrap).
set -eo pipefail
# an unexpected failure says where, rather than stopping the add-on silently
trap 'bashio::log.error "ffs-db-prepare: failed at line ${LINENO}: ${BASH_COMMAND}"' ERR
# shellcheck source=common.sh
. /usr/lib/firefox-sync/common.sh
ffs_load

if [ "${SYNC_DB_CONTAINERS}" != 1 ]; then
  bashio::log.info "The MariaDB add-on holds the databases: no bundled MariaDB"
  exit 0
fi

server=$(ffs_server_major)
[ -n "${server}" ] || bashio::exit.nok "cannot read the version of the bundled mariadbd"
touch "${FFS_PINS}"
chmod 600 "${FFS_PINS}"
pin=$(ffs_env_get "${FFS_PINS}" SYNC_MARIADB_IMAGE)
pinned=${pin#mariadb:}

mkdir -p "${FFS_DATADIR}" /run/mysqld
chown mysql:mysql /run/mysqld
chmod 700 "${FFS_DATADIR}"

if [ ! -d "${FFS_DATADIR}/mysql" ]; then
  bashio::log.info "A new MariaDB ${server} data directory in ${FFS_DATADIR}"
  rm -rf "${FFS_DATADIR:?}"/*
  chown mysql:mysql "${FFS_DATADIR}"
  mariadb-install-db --user=mysql --datadir="${FFS_DATADIR}" --auth-root-authentication-method=socket \
    --skip-test-db > /tmp/mariadb-install-db.log 2>&1 || { cat /tmp/mariadb-install-db.log; bashio::exit.nok "mariadb-install-db failed"; }
  ffs_env_put "${FFS_PINS}" SYNC_MARIADB_IMAGE "mariadb:${server}"
  if ls "${FFS_DUMP_DIR}"/firefox-sync-*.sql.gz > /dev/null 2>&1; then
    bashio::log.warning "No data directory, but a dump in ${FFS_DUMP_DIR}: it is loaded after the start (a restored backup)"
    touch "${FFS_DATADIR}/.ffs-restore-pending"
  fi
  exit 0
fi

data=$(ffs_data_major "${FFS_DATADIR}")
was=${pinned:-${data}}
if [ -z "${pinned}" ] && [ -n "${data}" ]; then
  # data from before the pin: pinned to what it holds
  ffs_env_put "${FFS_PINS}" SYNC_MARIADB_IMAGE "mariadb:${data}"
fi
if [ -n "${was}" ] && [ "${was}" != "${server}" ]; then
  if [ "${was}" -gt "${server}" ]; then
    bashio::exit.nok "The data in ${FFS_DATADIR} is MariaDB ${was}, newer than this add-on's MariaDB ${server}: MariaDB cannot go back. Restore a backup taken with MariaDB ${server}, or install the add-on version you had"
  fi
  if [ "${FFS_MARIADB_UPGRADE}" != true ]; then
    bashio::log.error "The data in ${FFS_DATADIR} is MariaDB ${was}, this version of the add-on has MariaDB ${server}."
    bashio::log.error "Not started: the server would upgrade the data to ${server} for good, with no way back but a backup."
    bashio::log.error "To stay on ${was}: install the add-on version you had. To move to ${server}: take a Home Assistant"
    bashio::log.error "backup of this add-on, then turn on sync_mariadb_upgrade (Configuration, show unused optional options) and start it again."
    exit 1
  fi
  bashio::log.warning "Upgrading the data from MariaDB ${was} to ${server} (sync_mariadb_upgrade is on)"
  touch "${FFS_DATADIR}/.ffs-upgrade-pending"
fi
chown -R mysql:mysql "${FFS_DATADIR}"
