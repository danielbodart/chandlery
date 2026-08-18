# syntax=docker/dockerfile:1
#
# Valheim Dedicated Server — pinned, not baked.
#
# The image carries no game content: the Steam Subscriber Agreement forbids
# reproducing or distributing it, and a public image would do exactly that
# (PLAN 7.3). It records instead precisely *which* build — the depot and the
# immutable manifest gid — and fetches those exact bytes with SteamCMD on first
# start. Pinning the manifest, not just the public branch, is what makes a
# Valheim build reproducible: the same gid always fetches the same bytes, which
# app_update-then-verify could never promise.
#
# The tag stays the human-facing build id of the public branch; the gid is the
# content address underneath it. Both travel as image environment.
ARG BASE=chandlery/base:test

FROM golang:1.24-bookworm AS probe
WORKDIR /src
COPY probe/go.mod probe/main.go probe/main_test.go ./
# The health check decides whether a live server gets replaced, so its tests run
# as part of building it.
RUN CGO_ENABLED=0 go test ./... && CGO_ENABLED=0 go build -trimpath -o /chandlery-a2s .

FROM ${BASE}

# No defaults for the two that identify the build: see bedrock/Dockerfile.
# Building "some build of Valheim" is the thing this project exists to prevent.
ARG VALHEIM_BUILD_ID
ARG VALHEIM_MANIFEST_GID
ARG VALHEIM_APP_ID=896660
ARG VALHEIM_DEPOT_ID=896661

USER root
RUN set -eux; \
    test -n "${VALHEIM_BUILD_ID}"   || { echo "VALHEIM_BUILD_ID build-arg is required" >&2; exit 64; }; \
    test -n "${VALHEIM_MANIFEST_GID}" || { echo "VALHEIM_MANIFEST_GID build-arg is required" >&2; exit 64; }; \
    dpkg --add-architecture i386; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl \
# SteamCMD itself is a 32-bit binary, whatever it goes on to download.
        lib32gcc-s1; \
    rm -rf /var/lib/apt/lists/*; \
# SteamCMD is Valve's freely-redistributable client tool, not the game — baking
# it saves fetching it on every first boot. It self-updates on first run.
    mkdir -p /opt/steamcmd; \
    curl -fsSL --http1.1 --retry 5 --retry-delay 5 --retry-all-errors \
         https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
      | tar -xz -C /opt/steamcmd; \
    chown -R chandlery:chandlery /opt/steamcmd

RUN --mount=type=secret,id=extra-ca \
    if [ -s /run/secrets/extra-ca ]; then \
        cp /run/secrets/extra-ca /usr/local/share/ca-certificates/extra-ca.crt; \
        update-ca-certificates; \
    fi

COPY --from=probe /chandlery-a2s /usr/local/bin/chandlery-a2s
COPY --chmod=0755 fetch     /usr/local/lib/chandlery/fetch
COPY --chmod=0755 run       /usr/local/bin/valheim-server
COPY --chmod=0755 prepare   /usr/local/lib/chandlery/prepare
COPY --chmod=0755 stop-hook /usr/local/lib/chandlery/stop
COPY --chmod=0755 health    /usr/local/lib/chandlery/health

# The pin travels as environment: prepare fetches the gid, run locates it, and
# `docker inspect` shows exactly which build a first start will pull.
ENV VALHEIM_BUILD_ID=${VALHEIM_BUILD_ID} \
    VALHEIM_MANIFEST_GID=${VALHEIM_MANIFEST_GID} \
    VALHEIM_APP_ID=${VALHEIM_APP_ID} \
    VALHEIM_DEPOT_ID=${VALHEIM_DEPOT_ID}

USER chandlery
WORKDIR /data

LABEL org.opencontainers.image.title="Valheim Dedicated Server" \
      org.opencontainers.image.version="${VALHEIM_BUILD_ID}" \
      org.opencontainers.image.source="https://github.com/danielbodart/chandlery" \
      org.opencontainers.image.licenses="Apache-2.0"

# 2456 is the game, 2457 the Steam query port. Valheim derives the second from
# the first and will not let you set them independently.
EXPOSE 2456/udp 2457/udp

# Loading a large world takes a while, and the first start fetches ~1.6 GB with
# SteamCMD before that; a restart loop during either is how you corrupt a world.
HEALTHCHECK --interval=30s --timeout=10s --start-period=300s --retries=3 \
    CMD ["/usr/local/lib/chandlery/health"]

CMD ["/usr/local/bin/valheim-server"]
