#!/bin/bash
# shellcheck shell=bash
# The Sync server with compose's environment of syncstorage (compose/sync.yml, sync-mariadb.yml)
set -eo pipefail
# shellcheck source=common.sh
. /usr/lib/firefox-sync/common.sh
ffs_load
# shellcheck source=sync-env.sh
. /usr/lib/firefox-sync/sync-env.sh
if [ "${FFS_ADMIN}" = true ]; then
  # metrics for the admin UI (statsd, UDP)
  vars+=(SYNC_STATSD_HOST=127.0.0.1 SYNC_STATSD_PORT=8125)
  echo "Sending metrics to the admin UI"
fi
cd /app
exec env -i "${vars[@]}" /command/s6-setuidgid app /app/bin/syncserver
