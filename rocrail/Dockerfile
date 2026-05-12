# Rocrail HA Add-on
# Base: Debian Trixie (slim)
#
# This image ships NO Rocrail binary. The Rocrail server is downloaded
# at runtime by run.sh, on the user's machine, directly from
# rocrail.online. See LICENSE / README for the rationale (we are a
# wrapper, not a Rocrail re-distributor).

ARG BUILD_FROM=debian:13-slim
# hadolint ignore=DL3006
FROM ${BUILD_FROM}

ARG BUILD_ARCH
ARG BUILD_VERSION="dev"
ARG BASHIO_VERSION="0.16.2"

ENV LANG=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive

# ----- Runtime dependencies -----
# curl + unzip are required at runtime (run.sh fetches the Rocrail zip
# from rocrail.online and extracts it into /data/rocrail). jq is used
# by bashio and by the Supervisor-API helpers in run.sh.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        jq \
        tini \
        tzdata \
        unzip \
        libwxgtk3.2-1t64 \
        libwxbase3.2-1t64 \
        libusb-1.0-0 \
        libxml2 \
    && rm -rf /var/lib/apt/lists/*

# ----- Install bashio -----
RUN set -eux; \
    curl -fsSL "https://github.com/hassio-addons/bashio/archive/refs/tags/v${BASHIO_VERSION}.tar.gz" \
        -o /tmp/bashio.tar.gz; \
    tar xzf /tmp/bashio.tar.gz -C /tmp; \
    mv /tmp/bashio-${BASHIO_VERSION}/lib /usr/lib/bashio; \
    ln -s /usr/lib/bashio/bashio /usr/bin/bashio; \
    rm -rf /tmp/bashio.tar.gz /tmp/bashio-${BASHIO_VERSION}

# Library path: run.sh installs Rocrail under /data/rocrail/, with .so
# files appearing in bin/, lib/ or the install root depending on the
# upstream zip layout for that revision. Cover all three locations.
ENV LD_LIBRARY_PATH=/data/rocrail:/data/rocrail/bin:/data/rocrail/lib

# ----- Copy rootfs into the image -----
COPY rootfs/ /
RUN chmod +x /run.sh

LABEL \
    io.hass.name="Rocrail" \
    io.hass.description="Rocrail Model Railroad Control System" \
    io.hass.type="addon" \
    io.hass.version="${BUILD_VERSION}" \
    io.hass.arch="${BUILD_ARCH}" \
    org.opencontainers.image.title="Rocrail Add-on" \
    org.opencontainers.image.version="${BUILD_VERSION}" \
    org.opencontainers.image.source="https://github.com/magliaral/ha-addon-rocrail" \
    org.opencontainers.image.licenses="MIT"

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/run.sh"]
