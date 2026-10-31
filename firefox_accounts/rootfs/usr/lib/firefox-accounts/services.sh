#!/bin/bash
# shellcheck shell=bash
# The long-running services of compose/fxa.yml, each with its environment there and nothing
# else, as its own user (the Dockerfile): services.sh <service> (the s6 run scripts call it).
#   auth (app, the image's: the keys, /fxa) content (fxa-content) profile profile-worker
#   profile-static (fxa-profile: the avatars) img-proxy (fxa-imgproxy) pairing (fxa-pairing)
set -o pipefail
# shellcheck source=common.sh
. /usr/lib/firefox-accounts/common.sh
fxa_load
fxa_node_env
SERVICE=${1:?service}
PROFILE_DIR=/fxa/packages/fxa-profile-server

# the Redis clients of the accounts (the chart's fxaRedisEnv): each host, and its password
redis_env() {
  local name
  for name in "$@"; do
    vars+=("${name}=127.0.0.1" "${name%HOST}PASSWORD=${FXA_REDIS_PASSWORD}")
  done
}
mysql_env() { # mysql_env <prefix>: compose's x-fxa-mysql
  vars+=("$1MYSQL_HOST=${FXA_MYSQL_HOST}" "$1MYSQL_PORT=${FXA_MYSQL_PORT}" "$1MYSQL_USERNAME=${FXA_MYSQL_USER}" "$1MYSQL_PASSWORD=${FXA_MYSQL_PASSWORD}")
}
run() { # run <user> <command>...
  local user=$1
  shift
  exec env -i "${vars[@]}" /command/s6-setuidgid "${user}" "$@"
}

case "${SERVICE}" in
  auth)
    cd /fxa/packages/fxa-auth-server/dist/packages/fxa-auth-server || exit 1
    # shellcheck disable=SC2054 # (SERVICES_WITH_EMAIL_VERIFICATION: a comma-separated value)
    vars+=(
      NODE_ENV=prod
      "CONFIG_FILES=${FXA_KEYS}/oauth-clients.json"
      IP_ADDRESS=0.0.0.0
      "PUBLIC_URL=${FXA_AUTH_URL}" "OAUTH_URL=${FXA_AUTH_URL}"
      "CONTENT_SERVER_URL=${FXA_CONTENT_URL}" "FXA_OPENID_ISSUER=${FXA_CONTENT_URL}"
      "ISSUER=${FXA_EMAIL_DOMAIN}"
      PROFILE_SERVER_URL=http://127.0.0.1:1111
      "SYNC_TOKENSERVER_URL=${SYNC_PUBLIC_URL}"
      "CORS_ORIGIN=${FXA_CONTENT_URL}"
      CLIENT_ADDRESS_DEPTH=2
      "FXA_EXPIRATION_ACCESS_TOKEN=60 minutes"
      LASTACCESSTIME_UPDATES_SAMPLE_RATE=1
      ADMIN_FXA_CLIENT_ID= ADMIN_FXA_CLIENT_SECRET= ADMIN_OIDC_REDIRECT_URL=
      SERVICES_WITH_EMAIL_VERIFICATION=32aaeb6f1c21316a,98e6508e88680e1a,
      "OAUTH_SERVER_SECRET_KEY=${FXA_OAUTH_SECRET}" "OAUTH_SERVER_SECRETS=${FXA_OAUTH_SECRET}"
      "AUTH_SERVER_SECRETS=${FXA_OAUTH_SECRET}" "AUTH_SERVER_SHARED_SECRET=${FXA_AUTH_SECRET}"
      "PROFILE_SERVER_AUTH_SECRET_BEARER_TOKEN=${FXA_PROFILE_SECRET}"
      "FLOW_ID_KEY=${FXA_FLOW_ID_KEY}" "SESSION_TOKEN_HANDLE_KEY=${FXA_SESSION_TOKEN_HANDLE_KEY}"
      "SECRET_KEY_FILE=${FXA_KEYS}/secret-key.json" "PUBLIC_KEY_FILE=${FXA_KEYS}/public-key.json"
      "VAPID_KEYS_FILE=${FXA_KEYS}/vapid-keys.json" "FXA_OPENID_KEYFILE=${FXA_KEYS}/openid-key.json"
      "FXA_OPENID_NEWKEYFILE=${FXA_KEYS}/openid-newKey.json" "FXA_OPENID_OLDKEYFILE=${FXA_KEYS}/openid-oldKey.json"
      DB=mysql
      PUSHBOX_ENABLED=true
      DB_AUTO_UPDATE_CLIENTS=true
      "SMTP_HOST=${FXA_SMTP_HOST}" "SMTP_PORT=${FXA_SMTP_PORT}" "SMTP_USER=${FXA_SMTP_USER}"
      "SMTP_PASS=${FXA_SMTP_PASS}" "SMTP_SECURE=${FXA_SMTP_SECURE}" "SMTP_SENDER=${FXA_SMTP_SENDER}"
      FIRESTORE_ENABLED=false SNS_TOPIC_ARN=disabled GEODB_ENABLED=false AUTH_GLEAN_ENABLED=false
      CUSTOMS_SERVER_URL=none RECOVERY_PHONE__ENABLED=false RECOVERY_PHONE__TWILIO__CREDENTIAL_MODE=
      ACCOUNT_EVENTS_ENABLED=false
      IP_PROFILING_RECENCY=0
      LOG_LEVEL=INFO
    )
    mysql_env AUTH_
    mysql_env ""
    mysql_env PUSHBOX_
    redis_env REDIS_HOST ACCESS_TOKEN_REDIS_HOST REFRESH_TOKEN_REDIS_HOST CUSTOMS_REDIS_HOST RATELIMIT_REDIS_HOST \
      METRICS_REDIS_HOST AUTH_CACHE_REDIS_HOST RECOVERY_PHONE_REDIS_HOST PASSKEY_REDIS_HOST
    # keys are only generated when missing: /data keeps them (never generated again)
    run app sh -c 'node scripts/gen_keys.js && node scripts/oauth_gen_keys.js && node scripts/gen_vapid_keys.js &&
      node "$0/oauth-clients.js" "$1/oauth-clients.json" && exec node bin/key_server.js' "${FXA_CONFIG}" "${FXA_KEYS}"
    ;;
  content)
    cd /fxa/packages/fxa-content-server || exit 1
    # shellcheck disable=SC2054 # (SERVICES_WITH_EMAIL_VERIFICATION: a comma-separated value)
    vars+=(
      NODE_ENV=production
      CONFIG_FILES=/run/fxa-content/content-server.json
      "CONTENT_SESSION_SECRET=${FXA_CONTENT_SESSION_SECRET}"
      "PUBLIC_URL=${FXA_CONTENT_URL}"
      "FXA_URL=${FXA_AUTH_URL}" "FXA_OAUTH_URL=${FXA_AUTH_URL}"
      "FXA_PROFILE_URL=${FXA_PROFILE_URL}" "FXA_PROFILE_IMAGES_URL=${FXA_PROFILE_URL}/img"
      "SYNC_TOKENSERVER_URL=${SYNC_PUBLIC_URL}"
      "PAIRING_SERVER_BASE_URI=${FXA_PAIRING_URL:-wss://channelserver.services.mozilla.com}"
      SERVICES_WITH_EMAIL_VERIFICATION=32aaeb6f1c21316a,
      "FLOW_ID_KEY=${FXA_FLOW_ID_KEY}"
      GEODB_ENABLED=false
    )
    redis_env FEATURE_FLAGS_REDIS_HOST REDIS_HOST
    # its session secret goes to a file (content-server.js): in its own directory, not in /tmp
    install -d -m 0700 -o fxa-content -g fxa-content /run/fxa-content
    run fxa-content sh -c 'node "$0/content-server.js" /run/fxa-content/content-server.json && exec node server/bin/fxa-content-server.js' "${FXA_CONFIG}"
    ;;
  profile)
    cd "${PROFILE_DIR}" || exit 1
    vars+=(
      NODE_ENV=production HOST=0.0.0.0 DB=mysql
      "PUBLIC_URL=${FXA_PROFILE_URL}"
      AUTH_SERVER_URL=http://127.0.0.1:9000/v1 OAUTH_SERVER_URL=http://127.0.0.1:9000/v1
      "AUTH_SECRET_BEARER_TOKEN=${FXA_PROFILE_SECRET}"
      WORKER_URL=http://127.0.0.1:1113
      IMG=local
      "IMG_URL=${FXA_PROFILE_URL}/img/a/{id}"
      "IMG_PROVIDERS_FXA=^${FXA_PROFILE_URL}/img/a/[0-9a-f]{32}$"
      EVENTS_ENABLED=false
    )
    mysql_env ""
    redis_env REDIS_HOST
    run fxa-profile node bin/server.js
    ;;
  profile-worker)
    cd "${PROFILE_DIR}" || exit 1
    vars+=(NODE_ENV=production WORKER_HOST=127.0.0.1 IMG=local)
    run fxa-profile node bin/worker.js
    ;;
  profile-static)
    cd "${PROFILE_DIR}" || exit 1
    vars+=(NODE_ENV=production HOST=127.0.0.1 IMG=local)
    run fxa-profile node bin/_static.js
    ;;
  img-proxy)
    # the chart's img-proxy: /img/<path> on 1114 is the static server's /<path>
    vars+=(NODE_ENV=production)
    run fxa-imgproxy node "${FXA_CONFIG}/img-proxy.js"
    ;;
  pairing)
    cd /opt/channelserver || exit 1
    exec env -i PATH=/usr/bin:/bin PAIR_HOSTNAME=0.0.0.0 PAIR_PORT=8000 PAIR_HUMAN_LOGS=true \
      PAIR_TRUSTED_PROXY_LIST=127.0.0.1,172.16.0.0/12,10.0.0.0/8,192.168.0.0/16 \
      /command/s6-setuidgid fxa-pairing /opt/channelserver/bin/channelserver
    ;;
  *) echo "services.sh: unknown service ${SERVICE}" >&2; exit 2 ;;
esac
