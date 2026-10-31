#!/bin/bash
# shellcheck shell=bash
# ffs-migrate (oneshot): compose's syncstorage_migrate. The database migrations (and the Sync
# node) without exposing the server: syncstorage-rs started until it answers, then stopped,
# so that SYNC_MAX_USERS is in force before anybody can reach it. Fails closed.
set -o pipefail
# shellcheck source=common.sh
. /usr/lib/firefox-sync/common.sh
ffs_load
# shellcheck source=sync-env.sh
. /usr/lib/firefox-sync/sync-env.sh
case "${SYNC_PUBLIC_URL:-}" in
  "") echo "ERROR: the public Sync URL (sync_public_url) is empty"; exit 1 ;;
esac
cd /app || exit 1
pid=
# shellcheck disable=SC2154 # (vars: sync-env.sh)
for _ in $(seq 1 120); do
  # (re)start syncstorage-rs until the databases accept connections
  if [ -z "${pid}" ] || ! kill -0 "${pid}" 2> /dev/null; then
    env -i "${vars[@]}" SYNC_PORT=8000 /command/s6-setuidgid app /app/bin/syncserver &
    pid=$!
  fi
  if curl -sf http://localhost:8000/__heartbeat__ > /dev/null; then
    # its graceful shutdown can hang for good (workers that never stop): killed 30 s after SIGTERM
    kill "${pid}"
    (sleep 30; kill -0 "${pid}" 2> /dev/null && echo "syncstorage-rs still running 30 s after SIGTERM, killed" && kill -9 "${pid}") &
    wait "${pid}"
    kill $! 2> /dev/null
    echo "Migrations completed"
    exit 0
  fi
  sleep 1
done
echo "Timeout waiting for syncstorage-rs to start"
kill "${pid}"
exit 1
