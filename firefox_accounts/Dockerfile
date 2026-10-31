# syntax=docker/dockerfile:1
# Mozilla accounts (self-hosted) for Home Assistant: the accounts' servers of firefox-sync's
# fxa-mono image, its pairing server, Redis and (optionally) MariaDB in one container,
# supervised by s6-overlay v3 (rootfs/etc/s6-overlay). compose/fxa.yml of firefox-sync, one
# service per s6 service.
#
#   IMAGE_REPOSITORY  where the firefox-sync images come from. FOR NOW the dev repository,
#                     until the testing is done and the images are promoted; then this one
#                     line becomes ghcr.io/porelli/firefox-sync (the public repository)
#   IMAGE_TAG         their tag suffix: latest (fxa-mono-latest, fxa-channelserver-latest...)
#   MARIADB_SERIES    the bundled MariaDB, from MariaDB's repository: latest-LTS when built
ARG IMAGE_REPOSITORY=ghcr.io/porelli/firefox-sync-dev
ARG IMAGE_TAG=latest

# the sign-up policy (ffs-admin fxa-init), the pairing server, s6-overlay with bashio
FROM ${IMAGE_REPOSITORY}:admin-${IMAGE_TAG} AS admin
FROM ${IMAGE_REPOSITORY}:fxa-channelserver-${IMAGE_TAG} AS pairing
# SEAM (db-bootstrap): firefox-sync's db/db-setup.sh and its SQL, copied in seam/db-bootstrap/
# until the db-bootstrap branch is merged and an image ships them (seam/db-bootstrap/SOURCE).
# The swap is this stage alone: FROM that image, COPY its folder to /, and delete seam/
FROM scratch AS db-bootstrap
COPY seam/db-bootstrap/ /

FROM ghcr.io/home-assistant/base-debian:bookworm AS ha

# Mozilla's accounts (Node.js on Debian bookworm), with the upstream patches of firefox-sync
FROM ${IMAGE_REPOSITORY}:fxa-mono-${IMAGE_TAG}

# s6-overlay runs as root; each service drops to its own user (s6-setuidgid)
# hadolint ignore=DL3002
USER 0
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG MARIADB_SERIES=latest-LTS
ARG BUILD_ARCH
ARG BUILD_VERSION

# Redis (the accounts' cache), MariaDB server and client, jq (bashio)
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl gnupg jq redis-server \
    && curl -fsSL https://r.mariadb.com/downloads/mariadb_repo_setup \
        | bash -s -- --mariadb-server-version="${MARIADB_SERIES}" --skip-maxscale --skip-tools \
    && apt-get update \
    && apt-get install -y --no-install-recommends mariadb-server mariadb-client \
    && rm -rf /var/lib/apt/lists/* /var/lib/mysql/* \
    && mariadbd --version && dpkg-query -W redis-server

COPY --from=ha /init /init
COPY --from=ha /package /package
COPY --from=ha /command /command
COPY --from=ha /etc/s6-overlay /etc/s6-overlay
COPY --from=ha /usr/lib/bashio /usr/lib/bashio
RUN ln -sf /usr/lib/bashio/bashio /usr/bin/bashio
COPY --from=admin /ffs-admin /usr/local/bin/ffs-admin
COPY --from=pairing /app/bin/channelserver /opt/channelserver/bin/channelserver
COPY --from=pairing /app/mmdb /opt/channelserver/mmdb
COPY --from=pairing /app/version.json /opt/channelserver/version.json

# the avatars live in /data: the image's directory (the default avatar) seeds it at the start
RUN mv /fxa/packages/fxa-profile-server/var/public /fxa/packages/fxa-profile-server/var/public.dist \
    && ln -s /data/fxa-profile-images /fxa/packages/fxa-profile-server/var/public

COPY rootfs /
COPY --from=db-bootstrap / /usr/share/firefox-accounts/db/
RUN chmod 0755 /usr/bin/fxa-* /usr/lib/firefox-accounts/*.sh /usr/share/firefox-accounts/db/db-setup.sh \
    && find /etc/s6-overlay/s6-rc.d -name run -exec chmod 0755 {} +

ENV \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0 \
    S6_CMD_WAIT_FOR_SERVICES=1 \
    S6_SERVICES_READYTIME=50 \
    S6_KILL_GRACETIME=20000

# the Supervisor's watchdog: the API and the pages answer (the first start migrates for minutes)
HEALTHCHECK --start-period=10m --interval=30s --timeout=10s --retries=5 \
    CMD ["sh", "-c", "curl -sf -o /dev/null http://127.0.0.1:9000/__lbheartbeat__ && curl -sf -o /dev/null http://127.0.0.1:3030/__lbheartbeat__"]

WORKDIR /
ENTRYPOINT ["/init"]
CMD []

LABEL \
    io.hass.version="${BUILD_VERSION}" \
    io.hass.type="app" \
    io.hass.arch="${BUILD_ARCH}" \
    org.opencontainers.image.title="Home Assistant App: Mozilla accounts (self-hosted)" \
    org.opencontainers.image.description="Self-hosted Mozilla accounts for the Firefox Sync add-on" \
    org.opencontainers.image.source="https://github.com/porelli/hassio-addons" \
    org.opencontainers.image.licenses="MPL-2.0"
