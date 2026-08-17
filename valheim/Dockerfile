# syntax=docker/dockerfile:1
#
# Valheim Dedicated Server, baked in at build time.
#
# Steam has no version string for a dedicated server, so the tag is the build
# id of the public branch: chandlery/valheim:21981590 is exactly that build.
ARG BASE=chandlery/base:test

FROM golang:1.24-bookworm AS probe
WORKDIR /src
COPY probe/go.mod probe/main.go probe/main_test.go ./
# The health check is the thing that decides whether a live server gets
# replaced, so its tests run as part of building it.
RUN CGO_ENABLED=0 go test ./... && CGO_ENABLED=0 go build -trimpath -o /chandlery-a2s .

FROM debian:bookworm-slim AS fetch

# No default: see bedrock/Dockerfile. Building "some build of Valheim" is the
# thing this project exists to prevent.
ARG VALHEIM_BUILD_ID
ARG VALHEIM_APP_ID=896660

RUN set -eux; \
    dpkg --add-architecture i386; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl \
# SteamCMD itself is a 32-bit binary, whatever it goes on to download.
        lib32gcc-s1; \
    rm -rf /var/lib/apt/lists/*

RUN --mount=type=secret,id=extra-ca \
    if [ -s /run/secrets/extra-ca ]; then \
        cp /run/secrets/extra-ca /usr/local/share/ca-certificates/extra-ca.crt; \
        update-ca-certificates; \
    fi

RUN set -eux; \
    test -n "${VALHEIM_BUILD_ID}" || { echo "VALHEIM_BUILD_ID build-arg is required" >&2; exit 64; }; \
    mkdir -p /opt/steamcmd; \
    curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors \
         https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
      | tar -xz -C /opt/steamcmd; \
# validate makes SteamCMD checksum every file it wrote, which is the closest
# thing to a verified artefact Steam offers.
    /opt/steamcmd/steamcmd.sh \
        +force_install_dir /stage/valheim \
        +login anonymous \
        +app_update "${VALHEIM_APP_ID}" validate \
        +quit; \
    test -x /stage/valheim/valheim_server.x86_64; \
# Confirm we baked the build we were asked for, rather than whatever Steam
# happened to be serving by the time the download ran.
    got=$(awk -F'"' '/"buildid"/ { print $4; exit }' \
          /stage/valheim/steamapps/appmanifest_${VALHEIM_APP_ID}.acf); \
    if [ "$got" != "${VALHEIM_BUILD_ID}" ]; then \
        echo "asked for build ${VALHEIM_BUILD_ID}, Steam served ${got}" >&2; exit 65; \
    fi; \
    rm -rf /stage/valheim/steamapps/downloading /stage/valheim/steamapps/temp

FROM ${BASE}

ARG VALHEIM_BUILD_ID
USER root

# The server is 64-bit; the steamclient library it dlopens is shipped alongside.
COPY --from=fetch --chown=chandlery:chandlery /stage/valheim/ /opt/valheim/
COPY --from=probe /chandlery-a2s /usr/local/bin/chandlery-a2s
COPY --chmod=0755 run       /usr/local/bin/valheim-server
COPY --chmod=0755 prepare   /usr/local/lib/chandlery/prepare
COPY --chmod=0755 stop-hook /usr/local/lib/chandlery/stop
COPY --chmod=0755 health    /usr/local/lib/chandlery/health

USER chandlery
WORKDIR /opt/valheim

LABEL org.opencontainers.image.title="Valheim Dedicated Server" \
      org.opencontainers.image.version="${VALHEIM_BUILD_ID}" \
      org.opencontainers.image.source="https://github.com/danielbodart/chandlery" \
      org.opencontainers.image.licenses="Apache-2.0"

# 2456 is the game, 2457 the Steam query port. Valheim derives the second from
# the first and will not let you set them independently.
EXPOSE 2456/udp 2457/udp

# Loading a large world takes a while, and a restart loop during load is how
# you corrupt one.
HEALTHCHECK --interval=30s --timeout=10s --start-period=300s --retries=3 \
    CMD ["/usr/local/lib/chandlery/health"]

CMD ["/usr/local/bin/valheim-server"]
