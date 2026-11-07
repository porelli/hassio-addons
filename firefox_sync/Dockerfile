# syntax=docker/dockerfile:1
# Firefox Sync for Home Assistant: one container with the firefox-sync images' programs,
# supervised by s6-overlay v3 (rootfs/etc/s6-overlay/s6-rc.d).
#
#   IMAGE_REPOSITORY  where the firefox-sync images come from: the public repository. For a
#                     test build from the dev images, --build-arg
#                     IMAGE_REPOSITORY=ghcr.io/porelli/firefox-sync-dev (same tag names; the
#                     builder workflow does it when the FIREFOX_SYNC_IMAGES variable is set)
#   IMAGE_TAG         their tag suffix: latest (syncstorage-rs-mysql-latest, admin-latest...)
#   MARIADB_SERIES    the bundled MariaDB, from MariaDB's own repository: latest-LTS, the newest
#                     long-term series when the image is built. The data's major is kept in
#                     /data/firefox-sync.env: another major is refused unless allowed (DOCS.md)
ARG IMAGE_REPOSITORY=ghcr.io/porelli/firefox-sync
ARG IMAGE_TAG=latest

# the admin UI (a static Go binary), the init container's script and SQL (max users), and
# s6-overlay with bashio as Home Assistant's Debian base image has them
FROM ${IMAGE_REPOSITORY}:admin-${IMAGE_TAG} AS admin
FROM ${IMAGE_REPOSITORY}:syncstorage-rs-mysql-init-${IMAGE_TAG} AS init
# SEAM (db-bootstrap): firefox-sync's db/db-setup.sh and its SQL, copied in seam/db-bootstrap/
# until the db-bootstrap branch is merged and an image ships them (seam/db-bootstrap/SOURCE).
# The swap is this stage alone: FROM that image, COPY its folder to /, and delete seam/
FROM scratch AS db-bootstrap
COPY seam/db-bootstrap/ /

FROM ghcr.io/home-assistant/base-debian:trixie AS ha

# the Sync server's image (Debian, the syncserver binary with its Python modules) is the base
FROM ${IMAGE_REPOSITORY}:syncstorage-rs-mysql-${IMAGE_TAG}

# s6-overlay runs as root; each service drops to its own user (s6-setuidgid)
# hadolint ignore=DL3002
USER 0
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG MARIADB_SERIES=latest-LTS
ARG BUILD_ARCH
ARG BUILD_VERSION

# MariaDB server and client (the bundled database, the init script's client, the dumps),
# nginx (the ingress in front of the admin UI), jq (bashio)
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl gnupg jq nginx \
    && curl -fsSL https://r.mariadb.com/downloads/mariadb_repo_setup \
        | bash -s -- --mariadb-server-version="${MARIADB_SERIES}" --skip-maxscale --skip-tools \
    && apt-get update \
    && apt-get install -y --no-install-recommends mariadb-server mariadb-client \
    && rm -rf /var/lib/apt/lists/* /var/lib/mysql/* /etc/nginx/sites-enabled/* \
    && mariadbd --version

COPY --from=ha /init /init
COPY --from=ha /package /package
COPY --from=ha /command /command
COPY --from=ha /etc/s6-overlay /etc/s6-overlay
COPY --from=ha /usr/lib/bashio /usr/lib/bashio
RUN ln -sf /usr/lib/bashio/bashio /usr/bin/bashio
COPY --from=admin /ffs-admin /usr/local/bin/ffs-admin
# db_init.sh reads its SQL from /scripts
COPY --from=init /scripts /scripts

# the admin UI's own system user (no login, no home): not the Sync server's (app, the image's),
# not nobody; both face the internet (the Sync API, the sign-up gate)
RUN useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin ffs-admin

COPY rootfs /
COPY --from=db-bootstrap / /usr/share/firefox-sync/db/
RUN chmod 0755 /usr/bin/ffs-* /usr/lib/firefox-sync/*.sh /usr/share/firefox-sync/db/db-setup.sh \
    && find /etc/s6-overlay/s6-rc.d -name run -exec chmod 0755 {} +

ENV \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0 \
    S6_CMD_WAIT_FOR_SERVICES=1 \
    S6_SERVICES_READYTIME=50 \
    S6_KILL_GRACETIME=20000

# the Supervisor's watchdog: the Sync server answers (the migrations and the init ran first)
HEALTHCHECK --start-period=5m --interval=30s --timeout=10s --retries=5 \
    CMD ["curl", "-sf", "-o", "/dev/null", "http://127.0.0.1:8000/__heartbeat__"]

WORKDIR /
ENTRYPOINT ["/init"]
CMD []

LABEL \
    io.hass.version="${BUILD_VERSION}" \
    io.hass.type="app" \
    io.hass.arch="${BUILD_ARCH}" \
    org.opencontainers.image.title="Home Assistant App: Firefox Sync" \
    org.opencontainers.image.description="Firefox Sync server and the firefox-sync admin UI" \
    org.opencontainers.image.source="https://github.com/porelli/hassio-addons" \
    org.opencontainers.image.licenses="GPL-3.0"
