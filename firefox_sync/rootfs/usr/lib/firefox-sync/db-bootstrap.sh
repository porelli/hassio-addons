#!/command/with-contenv bashio
# shellcheck shell=bash
# ffs-db-bootstrap (oneshot): the databases and the stack's own users, with firefox-sync's
# bootstrap (db/db-setup.sh sync, SYNC_DB_BOOTSTRAP_USER): database-setup.sql applied as the
# bootstrap account at every start, then checked; a failure stops the add-on here.
#   bundled MariaDB: the account is the server's own ffs_bootstrap, created over the socket
#                    as root with db/mysql/bootstrap.sql (its grants: CREATE USER, and every
#                    privilege on the stack's three databases)
#   MariaDB add-on:  the account is the add-on's service user (the Supervisor's services API)
set -eo pipefail
# an unexpected failure says where, rather than stopping the add-on silently
trap 'bashio::log.error "ffs-db-bootstrap: failed at line ${LINENO}: ${BASH_COMMAND}"' ERR
# shellcheck source=common.sh
. /usr/lib/firefox-sync/common.sh
ffs_load

if [ "${SYNC_DB_CONTAINERS}" = 1 ]; then
  if [ -f "${FFS_DATADIR}/.ffs-upgrade-pending" ]; then
    bashio::log.warning "mariadb-upgrade: the data to MariaDB $(ffs_server_major)"
    mariadb-upgrade --protocol=socket -S "${FFS_SOCKET}" -u root || bashio::exit.nok "mariadb-upgrade failed: the data stays as it is, restore the backup or fix it by hand"
    ffs_env_put "${FFS_PINS}" SYNC_MARIADB_IMAGE "mariadb:$(ffs_server_major)"
    rm -f "${FFS_DATADIR}/.ffs-upgrade-pending"
  fi
  sed -e "s|@BOOTSTRAP_USER@|${SYNC_DB_BOOTSTRAP_USER}|g" -e "s|@BOOTSTRAP_PASSWORD@|${SYNC_DB_BOOTSTRAP_PASSWORD}|g" \
      -e "s|@SYNC_TOKENSERVER_DATABASE@|${SYNC_TOKENSERVER_DB_NAME}|g" -e "s|@SYNC_STORAGE_DATABASE@|${SYNC_STORAGE_DB_NAME}|g" \
      -e "s|@ADMIN_DATABASE@|${ADMIN_DB_NAME}|g" "${DB_DIR}/bootstrap.sql" | ffs_root_sql \
    || bashio::exit.nok "cannot create the bootstrap account on the bundled MariaDB"
fi

env -i PATH=/usr/bin:/bin FFS_DB_ENGINE=mariadb FFS_DB_DIR="${DB_DIR}" SYNC_DB_CONTAINERS=0 \
  "SYNC_DB_BOOTSTRAP_USER=${SYNC_DB_BOOTSTRAP_USER}" "SYNC_DB_BOOTSTRAP_PASSWORD=${SYNC_DB_BOOTSTRAP_PASSWORD}" \
  "SYNC_TOKENSERVER_DB_HOST=${SYNC_TOKENSERVER_DB_HOST}" "SYNC_TOKENSERVER_DB_PORT=${SYNC_TOKENSERVER_DB_PORT}" \
  "SYNC_TOKENSERVER_DB_NAME=${SYNC_TOKENSERVER_DB_NAME}" "SYNC_TOKENSERVER_DB_USER=${SYNC_TOKENSERVER_DB_USER}" \
  "SYNC_TOKENSERVER_DB_PASSWORD=${SYNC_TOKENSERVER_DB_PASSWORD}" \
  "SYNC_STORAGE_DB_HOST=${SYNC_STORAGE_DB_HOST}" "SYNC_STORAGE_DB_PORT=${SYNC_STORAGE_DB_PORT}" \
  "SYNC_STORAGE_DB_NAME=${SYNC_STORAGE_DB_NAME}" "SYNC_STORAGE_DB_USER=${SYNC_STORAGE_DB_USER}" \
  "SYNC_STORAGE_DB_PASSWORD=${SYNC_STORAGE_DB_PASSWORD}" "SYNC_DB_TLS_VERIFY=${SYNC_DB_TLS_VERIFY}" \
  "ADMIN_DB_USER=${ADMIN_DB_USER}" "ADMIN_DB_SYNC_USER=${ADMIN_DB_SYNC_USER}" \
  "ADMIN_DB_PASSWORD=${ADMIN_DB_PASSWORD}" "ADMIN_DB_NAME=${ADMIN_DB_NAME}" \
  bash "${DB_SETUP}" sync || bashio::exit.nok "the database bootstrap failed (above)"

# a restored backup: the dump of ffs-backup-pre into the new data directory (ffs-db-prepare),
# once the users exist (the definers of the triggers and procedures)
if [ "${SYNC_DB_CONTAINERS}" = 1 ] && [ -f "${FFS_DATADIR}/.ffs-restore-pending" ]; then
  dump=$(ls -1 "${FFS_DUMP_DIR}"/firefox-sync-*.sql.gz | tail -n 1)
  bashio::log.warning "Loading ${dump} into the new data directory"
  gunzip -c "${dump}" | ffs_root_sql || bashio::exit.nok "loading ${dump} failed"
  rm -f "${FFS_DATADIR}/.ffs-restore-pending"
  bashio::log.info "Restored the databases from ${dump}"
fi
