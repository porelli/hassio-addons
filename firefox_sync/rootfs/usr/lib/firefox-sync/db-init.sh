#!/bin/bash
# shellcheck shell=bash
# ffs-db-init (oneshot): the init container (syncstorage-rs-mysql-init's db_init.sh): the
# Sync node, SYNC_MAX_USERS and its trigger. Fails closed: the Sync server starts after it only.
set -o pipefail
# shellcheck source=common.sh
. /usr/lib/firefox-sync/common.sh
ffs_load
exec env -i PATH=/usr/bin:/bin "MAX_USERS=${SYNC_MAX_USERS}" "DOMAIN=${SYNC_PUBLIC_URL}" \
  "MARIADB_SERVER=${SYNC_TOKENSERVER_DB_HOST}" "MARIADB_SERVER_PORT=${SYNC_TOKENSERVER_DB_PORT}" \
  "MARIADB_DATABASE=${SYNC_TOKENSERVER_DB_NAME}" "MARIADB_USER=${SYNC_TOKENSERVER_DB_USER}" \
  "MARIADB_PASSWORD=${SYNC_TOKENSERVER_DB_PASSWORD}" "MARIADB_TLS_VERIFY=${SYNC_DB_TLS_VERIFY}" \
  bash /scripts/db_init.sh
