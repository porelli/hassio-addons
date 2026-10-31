#!/bin/bash
# shellcheck shell=bash
# fxa-files (oneshot): compose's fxa-keys-owner and the chart's images seed. The keys in /data,
# the auth server's (the image's user app, 10001); the avatars, the profile servers' (fxa-profile);
# the default avatar copied in, what is there kept.
set -eo pipefail
# shellcheck source=common.sh
. /usr/lib/firefox-accounts/common.sh
mkdir -p "${FXA_KEYS}" "${FXA_IMAGES}"
cp -an /fxa/packages/fxa-profile-server/var/public.dist/. "${FXA_IMAGES}/"
chown -R 10001:10001 "${FXA_KEYS}"
chown -R fxa-profile:fxa-profile "${FXA_IMAGES}"
chmod 700 "${FXA_KEYS}"
