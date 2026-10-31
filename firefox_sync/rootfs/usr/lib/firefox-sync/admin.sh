#!/bin/bash
# shellcheck shell=bash
# The admin UI with compose's environment of ffs-admin (compose/sync.yml, sync-mariadb.yml and,
# with the self-hosted accounts, fxa.yml), and nothing else: not the Sync server's secrets.
set -eo pipefail
# shellcheck source=common.sh
. /usr/lib/firefox-sync/common.sh
ffs_load

vars=(
  PATH=/usr/local/bin:/usr/bin:/bin
  SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
  "MAX_USERS=${SYNC_MAX_USERS}"
  "ADMIN_DB_USER=${ADMIN_DB_USER}" "ADMIN_DB_SYNC_USER=${ADMIN_DB_SYNC_USER}"
  "ADMIN_DB_PASSWORD=${ADMIN_DB_PASSWORD}" "ADMIN_DB_NAME=${ADMIN_DB_NAME}"
  SYNCSTORAGE_URL=http://127.0.0.1:8000
  "SYNCSTORAGE_DOMAIN=${SYNC_PUBLIC_URL}"
  "FXA_OAUTH_SERVER_URL=${FXA_OAUTH_SERVER_URL}" "FXA_EMAIL_DOMAIN=${FXA_EMAIL_DOMAIN}"
  ADMIN_PUBLIC_CHECK=true
  "METRICS_TOKEN=${ADMIN_METRICS_TOKEN}"
  # the commands its pages show: compose's are the nearest (there is no Home Assistant kind)
  ADMIN_DEPLOYMENT=compose
  "ADMIN_EXPORT_PORT=Home Assistant ingress"
  "ADMIN_AUTH_HEADER=${ADMIN_AUTH_HEADER}" "ADMIN_AUTH_GROUPS_HEADER=${ADMIN_AUTH_GROUPS_HEADER}"
  "ADMIN_TRUSTED_PROXIES=${ADMIN_TRUSTED_PROXIES}" "ADMIN_ALLOWED_GROUPS=${ADMIN_ALLOWED_GROUPS}"
  "ADMIN_TZ=${ADMIN_TZ}"
  # the backups are Home Assistant's: the dump of ffs-backup-pre records each run
  TOKENSERVER_DB_TYPE=mysql
  "TOKENSERVER_DB_HOST=${SYNC_TOKENSERVER_DB_HOST}" "TOKENSERVER_DB_PORT=${SYNC_TOKENSERVER_DB_PORT}"
  "TOKENSERVER_DB_NAME=${SYNC_TOKENSERVER_DB_NAME}" "TOKENSERVER_DB_USER=${SYNC_TOKENSERVER_DB_USER}"
  "TOKENSERVER_DB_PASSWORD=${ADMIN_DB_PASSWORD}"
  "STORAGE_DB_HOST=${SYNC_STORAGE_DB_HOST}" "STORAGE_DB_PORT=${SYNC_STORAGE_DB_PORT}"
  "STORAGE_DB_NAME=${SYNC_STORAGE_DB_NAME}" "STORAGE_DB_USER=${SYNC_STORAGE_DB_USER}"
  "STORAGE_DB_PASSWORD=${ADMIN_DB_PASSWORD}"
  "SYNC_DB=${SYNC_DB}"
)
if [ "${FFS_ACCOUNTS:-}" = self_hosted ]; then
  # compose/fxa.yml's ffs-admin, with the hosts of the accounts add-on (its link file)
  vars+=(
    "FXA_DB_HOST=${FXA_DB_HOST}" "FXA_DB_PORT=${FXA_DB_PORT}" "FXA_DB_PASSWORD=${FXA_DB_PASSWORD}"
    FXA_MAX_ACCOUNTS=initial:unlimited
    "FXA_AUTH_UPSTREAM=${FXA_AUTH_UPSTREAM}"
    "FXA_CONTENT_INTERNAL_URL=${FXA_CONTENT_INTERNAL_URL}" "FXA_PROFILE_INTERNAL_URL=${FXA_PROFILE_INTERNAL_URL}"
    "FXA_PAIRING_URL=${FXA_PAIRING_URL:-}" "FXA_PAIRING_INTERNAL_URL=${FXA_PAIRING_INTERNAL_URL:-}"
    "FXA_REDIS=${FXA_REDIS}" "FXA_REDIS_PASSWORD=${FXA_REDIS_PASSWORD}"
    "FXA_ACCOUNT_EVENTS=${FXA_ACCOUNT_EVENTS:-false}"
    "FXA_CONTENT_URL=${FXA_CONTENT_URL}" "FXA_AUTH_URL=${FXA_AUTH_URL}" "FXA_PROFILE_URL=${FXA_PROFILE_URL}"
    "FXA_DB=${FXA_DB:-mariadb}"
    "ADMIN_GATE_EXPORT_PORT=8081 on the add-on network"
    "FXA_CLIENT_ADDRESS_DEPTH=${FXA_CLIENT_ADDRESS_DEPTH:-2}"
    "FXA_ACCESS_TOKEN_LIFETIME=${FXA_ACCESS_TOKEN_LIFETIME:-60 minutes}"
    # the alerts by email: the accounts' SMTP server, as compose's FXA_SMTP_*
    "SMTP_HOST=${FXA_SMTP_HOST:-}" "SMTP_PORT=${FXA_SMTP_PORT:-587}" "SMTP_USER=${FXA_SMTP_USER:-}"
    "SMTP_PASS=${FXA_SMTP_PASS:-}" "SMTP_SECURE=${FXA_SMTP_SECURE:-false}" "SMTP_SENDER=${FXA_SMTP_SENDER:-}"
  )
fi
cd /tmp
exec env -i "${vars[@]}" /command/s6-setuidgid nobody /usr/local/bin/ffs-admin serve
