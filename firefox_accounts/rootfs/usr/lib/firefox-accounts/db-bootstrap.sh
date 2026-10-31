#!/command/with-contenv bashio
# shellcheck shell=bash
# fxa-db-bootstrap (oneshot): the accounts' users of db/mysql/fxa-mariadb.sql (fxa, ffs_policy,
# ffs_admin), with firefox-sync's bootstrap (db/db-setup.sh fxa, FXA_DB_BOOTSTRAP_USER), applied
# at every start then checked, before the migrations; a failure stops the add-on here.
#   bundled MariaDB: the account is the server's own ffs_bootstrap (db/mysql/fxa-bootstrap.sql)
#   MariaDB add-on:  the account is the add-on's service user
set -eo pipefail
trap 'bashio::log.error "fxa-db-bootstrap: failed at line ${LINENO}: ${BASH_COMMAND}"' ERR
# shellcheck source=common.sh
. /usr/lib/firefox-accounts/common.sh
fxa_load

if [ "${FXA_DB_CONTAINERS}" = 1 ]; then
  if [ -f "${FXA_DATADIR}/.fxa-upgrade-pending" ]; then
    bashio::log.warning "mariadb-upgrade: the data to MariaDB $(fxa_server_major)"
    mariadb-upgrade --protocol=socket -S "${FXA_SOCKET}" -u root || bashio::exit.nok "mariadb-upgrade failed"
    fxa_env_put "${FXA_PINS}" FXA_MARIADB_IMAGE "mariadb:$(fxa_server_major)"
    rm -f "${FXA_DATADIR}/.fxa-upgrade-pending"
  fi
  sed -e "s|@BOOTSTRAP_USER@|${FXA_DB_BOOTSTRAP_USER}|g" -e "s|@BOOTSTRAP_PASSWORD@|${FXA_DB_BOOTSTRAP_PASSWORD}|g" \
    "${DB_DIR}/bootstrap.sql" | fxa_root_sql || bashio::exit.nok "cannot create the bootstrap account on the bundled MariaDB"
fi

env -i PATH=/usr/bin:/bin FFS_DB_ENGINE=mariadb FFS_DB_DIR="${DB_DIR}" FXA_DB_CONTAINERS=0 \
  "FXA_DB_BOOTSTRAP_USER=${FXA_DB_BOOTSTRAP_USER}" "FXA_DB_BOOTSTRAP_PASSWORD=${FXA_DB_BOOTSTRAP_PASSWORD}" \
  "FXA_MYSQL_HOST=${FXA_MYSQL_HOST}" "FXA_MYSQL_PORT=${FXA_MYSQL_PORT}" \
  "FXA_MYSQL_USER=${FXA_MYSQL_USER}" "FXA_MYSQL_PASSWORD=${FXA_MYSQL_PASSWORD}" \
  "FXA_MYSQL_POLICY_USER=${FXA_MYSQL_POLICY_USER}" "FXA_MYSQL_POLICY_PASSWORD=${FXA_MYSQL_POLICY_PASSWORD}" \
  "FXA_ADMIN_DB_PASSWORD=${FXA_ADMIN_DB_PASSWORD}" \
  bash "${DB_SETUP}" fxa || bashio::exit.nok "the database bootstrap failed (above)"

# a restored backup: the dump of fxa-backup-pre (its own databases), once the users exist
if [ "${FXA_DB_CONTAINERS}" = 1 ] && [ -f "${FXA_DATADIR}/.fxa-restore-pending" ]; then
  dump=$(ls -1 "${FXA_DUMP_DIR}"/firefox-accounts-*.sql.gz | tail -n 1)
  bashio::log.warning "Loading ${dump} into the new data directory"
  gunzip -c "${dump}" | fxa_root_sql || bashio::exit.nok "loading ${dump} failed"
  rm -f "${FXA_DATADIR}/.fxa-restore-pending"
  bashio::log.info "Restored the accounts' databases from ${dump}"
fi
