#!/bin/bash
# shellcheck shell=bash
# fxa-files (oneshot): compose's fxa-keys-owner and the chart's images seed. The keys and the
# avatars in /data, the image's user's (10001); the default avatar copied in, what is there kept.
set -eo pipefail
# shellcheck source=common.sh
. /usr/lib/firefox-accounts/common.sh
mkdir -p "${FXA_KEYS}" "${FXA_IMAGES}"
cp -an /fxa/packages/fxa-profile-server/var/public.dist/. "${FXA_IMAGES}/"
chown -R 10001:10001 "${FXA_KEYS}" "${FXA_IMAGES}"
chmod 700 "${FXA_KEYS}"
