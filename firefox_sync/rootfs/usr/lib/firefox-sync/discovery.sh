#!/command/with-contenv bashio
# shellcheck shell=bash
# ffs-discovery (oneshot, once the admin UI is ready): the Supervisor's discovery for the
# firefox_sync integration, with the admin UI's address on the add-on network and the metrics
# token (ADMIN_METRICS_TOKEN). Not fatal: the integration can also be added by hand.
# shellcheck source=common.sh
. /usr/lib/firefox-sync/common.sh
ffs_load
if [ "${FFS_ADMIN}" != true ]; then
  bashio::log.info "No discovery: the admin UI is off"
  exit 0
fi
config=$(bashio::var.json host "${FFS_HOSTNAME}" port "^8080" metrics_token "${ADMIN_METRICS_TOKEN}" sync_public_url "${SYNC_PUBLIC_URL}")
if uuid=$(bashio::discovery "firefox_sync" "${config}"); then
  bashio::log.info "Sent the discovery for the Firefox Sync integration (${uuid})"
else
  bashio::log.warning "The Supervisor refused the discovery: add the Firefox Sync integration by hand (DOCS.md)"
fi
exit 0
