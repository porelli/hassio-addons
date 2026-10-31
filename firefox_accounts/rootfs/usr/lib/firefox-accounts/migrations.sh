#!/command/with-contenv bash
# shellcheck shell=bash
# fxa-migrations (oneshot): compose's fxa-migrations, Mozilla's db-migrations patcher, retried
# while the server does not answer. Fails closed: the accounts do not start without it.
. /usr/lib/firefox-accounts/common.sh
fxa_load
fxa_node_env
for db in AUTH OAUTH PROFILE PUSHBOX; do
  vars+=("${db}_MYSQL_HOST=${FXA_MYSQL_HOST}" "${db}_MYSQL_PORT=${FXA_MYSQL_PORT}"
    "${db}_MYSQL_USERNAME=${FXA_MYSQL_USER}" "${db}_MYSQL_PASSWORD=${FXA_MYSQL_PASSWORD}")
done
cd /fxa/packages/db-migrations || exit 1
for _ in $(seq 1 60); do
  env -i "${vars[@]}" /command/s6-setuidgid app node bin/patcher.mjs && exit 0
  sleep 5
done
exit 1
