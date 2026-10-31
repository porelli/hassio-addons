#!/bin/bash
# shellcheck shell=bash
# fxa-policy (oneshot): compose's fxa-policy, the admin image's fxa-init: who can sign up
# (FXA_SIGNUPS, FXA_SIGNUP_ALLOWLIST, FXA_MAX_ACCOUNTS) enforced by the accounts' database, and
# the grants of the admin UI's user (ffs_admin). Fails closed.
set -o pipefail
# shellcheck source=common.sh
. /usr/lib/firefox-accounts/common.sh
fxa_load
cd /tmp || exit 1
exec env -i PATH=/usr/local/bin:/usr/bin:/bin \
  "FXA_DB_HOST=${FXA_MYSQL_HOST}" "FXA_DB_PORT=${FXA_MYSQL_PORT}" \
  "FXA_DB_ROOT_USER=${FXA_MYSQL_POLICY_USER}" "FXA_DB_ROOT_PASSWORD=${FXA_MYSQL_POLICY_PASSWORD}" \
  "FXA_MYSQL_USER=${FXA_MYSQL_USER}" "FXA_MYSQL_PASSWORD=${FXA_MYSQL_PASSWORD}" \
  "FXA_ADMIN_DB_PASSWORD=${FXA_ADMIN_DB_PASSWORD}" \
  "FXA_SIGNUPS=${FXA_SIGNUPS}" "FXA_SIGNUP_ALLOWLIST=${FXA_SIGNUP_ALLOWLIST}" "FXA_MAX_ACCOUNTS=${FXA_MAX_ACCOUNTS}" \
  /command/s6-setuidgid nobody /usr/local/bin/ffs-admin fxa-init
