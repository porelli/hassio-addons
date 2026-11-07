# syntax=docker/dockerfile:1
# AirConnect for Home Assistant: philippe44's airupnp (UPnP/Sonos) and aircast (Chromecast)
# bridges, the binaries of an upstream release, each an s6-overlay v3 service
# (rootfs/etc/s6-overlay/s6-rc.d) on Home Assistant's Debian base image (glibc: the binaries
# need it, and nothing else).
#
#   AIRCONNECT_VERSION  the release of github.com/philippe44/AirConnect: latest (the newest one
#                       when the image is built) or a tag (1.12.4). Its zip is checked against
#                       the SHA-256 digest GitHub keeps for the release asset

# the download runs on the build machine; it takes the target's binaries
FROM --platform=${BUILDPLATFORM} ghcr.io/home-assistant/base-debian:trixie AS download
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG AIRCONNECT_VERSION=latest
ARG TARGETARCH
RUN apt-get update \
    && apt-get install -y --no-install-recommends unzip \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /download
RUN case "${TARGETARCH}" in \
        amd64) cpu=x86_64 ;; \
        arm64) cpu=aarch64 ;; \
        *) echo "no AirConnect binaries for ${TARGETARCH} here" >&2; exit 1 ;; \
    esac \
    && api=https://api.github.com/repos/philippe44/AirConnect/releases \
    && if [ "${AIRCONNECT_VERSION}" = latest ]; then url=${api}/latest; else url=${api}/tags/${AIRCONNECT_VERSION}; fi \
    && curl -fsSL -H "Accept: application/vnd.github+json" -o release.json "${url}" \
    && version=$(jq -er .tag_name release.json) \
    && asset="AirConnect-${version}.zip" \
    && digest=$(jq -er --arg n "${asset}" '.assets[] | select(.name == $n) | .digest' release.json) \
    && echo "${digest}" | grep -Eq '^sha256:[0-9a-f]{64}$' \
    && curl -fsSL -o "${asset}" "https://github.com/philippe44/AirConnect/releases/download/${version}/${asset}" \
    && echo "${digest#sha256:}  ${asset}" | sha256sum -c - \
    && unzip -q -j "${asset}" "airupnp-linux-${cpu}" "aircast-linux-${cpu}" \
    && install -D -m 0755 "airupnp-linux-${cpu}" /out/usr/bin/airupnp \
    && install -D -m 0755 "aircast-linux-${cpu}" /out/usr/bin/aircast \
    && mkdir -p /out/usr/share/airconnect && echo "${version}" > /out/usr/share/airconnect/version \
    && echo "AirConnect ${version} (${cpu})"

FROM ghcr.io/home-assistant/base-debian:trixie
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG BUILD_ARCH
ARG BUILD_VERSION

# the bridges' own system user (no login, no home): they need no root
RUN useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin airconnect

COPY --from=download /out/ /
COPY rootfs /
# (the binaries load and run here: -h prints their usage, with a non-zero status)
RUN chmod 0755 /usr/lib/airconnect/bridge.sh /etc/s6-overlay/s6-rc.d/*/run \
    && { /usr/bin/airupnp -h 2>&1 || true; } | grep -q '^Usage' \
    && { /usr/bin/aircast -h 2>&1 || true; } | grep -q '^Usage'

ENV \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0 \
    S6_KILL_GRACETIME=5000

WORKDIR /
ENTRYPOINT ["/init"]
CMD []

LABEL \
    io.hass.version="${BUILD_VERSION}" \
    io.hass.type="app" \
    io.hass.arch="${BUILD_ARCH}" \
    org.opencontainers.image.title="Home Assistant App: AirConnect" \
    org.opencontainers.image.description="AirPlay to UPnP/Sonos and Chromecast bridges (philippe44/AirConnect)" \
    org.opencontainers.image.source="https://github.com/porelli/hassio-addons" \
    org.opencontainers.image.licenses="MIT AND GPL-3.0-or-later"
