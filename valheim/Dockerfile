# syntax=docker/dockerfile:1
#
# Valheim Dedicated Server — pinned, not baked.
#
# The image carries no game content: the Steam Subscriber Agreement forbids
# reproducing or distributing it (PLAN 7.3). It records precisely *which* build —
# the depot and the immutable manifest gid — and fetches those exact bytes on
# first start with DepotDownloader. Pinning the manifest (not just the public
# branch) is what makes rollback possible: an old gid still fetches its exact
# bytes, which is the whole reason to run these images.
#
# Anonymous login cannot download this depot ("No subscription"), so the fetch
# authenticates with the operator's own Steam account — a licensed account, its
# portable DepotDownloader token injected at runtime (image carries none), the
# same shape as Hytale's token passthrough.
#
# The tag is the human-facing *game* version (e.g. 0.221.12); the Steam build id
# and manifest gid ride along as labels, since only they are recoverable cheaply.
ARG BASE=chandlery/base:test
ARG DEPOTDOWNLOADER_VERSION=3.4.0
ARG DEPOTDOWNLOADER_SHA256=a999dec66b4850fc961bd50366696d23c2d0fad7b18790e6a5647b2f19097a53

FROM golang:1.24-bookworm AS probe
WORKDIR /src
COPY probe/go.mod probe/main.go probe/main_test.go ./
# The health check decides whether a live server gets replaced, so its tests run
# as part of building it.
RUN CGO_ENABLED=0 go test ./... && CGO_ENABLED=0 go build -trimpath -o /chandlery-a2s .

FROM ${BASE}

# No defaults for the three that identify the build: see bedrock/Dockerfile.
# Building "some build of Valheim" is the thing this project exists to prevent.
ARG VALHEIM_VERSION
ARG VALHEIM_BUILD_ID
ARG VALHEIM_MANIFEST_GID
ARG VALHEIM_APP_ID=896660
ARG VALHEIM_DEPOT_ID=896661
ARG DEPOTDOWNLOADER_VERSION
ARG DEPOTDOWNLOADER_SHA256

USER root
RUN set -eux; \
    test -n "${VALHEIM_VERSION}"      || { echo "VALHEIM_VERSION build-arg is required" >&2; exit 64; }; \
    test -n "${VALHEIM_BUILD_ID}"     || { echo "VALHEIM_BUILD_ID build-arg is required" >&2; exit 64; }; \
    test -n "${VALHEIM_MANIFEST_GID}" || { echo "VALHEIM_MANIFEST_GID build-arg is required" >&2; exit 64; }; \
    apt-get update; \
# ca-certificates + libicu for DepotDownloader (self-contained .NET). libatomic1
# and libpulse0 are the Valheim server's own runtime deps (per Iron Gate's Docker
# image). lib32gcc-s1 is for SteamCMD, which is a 32-bit binary.
    apt-get install -y --no-install-recommends \
        ca-certificates curl unzip libicu72 libatomic1 libpulse0 lib32gcc-s1; \
    rm -rf /var/lib/apt/lists/*; \
# SteamCMD (the script only — it self-updates on first run). The depot ships a
# stale (2022) steamclient.so that the server's Steam init rejects ("Missing
# interface adapter for SteamGameServer015"); SteamCMD keeps a *current* one, and
# the prepare hook refreshes it at start rather than baking a copy that would go
# stale in turn. DepotDownloader still does the authenticated, manifest-pinned
# game download — SteamCMD is only here for the client library.
    mkdir -p /opt/steamcmd; \
    curl -fsSL --http1.1 --retry 5 --retry-all-errors \
         https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
      | tar -xz -C /opt/steamcmd; \
    chown -R chandlery:chandlery /opt/steamcmd; \
# DepotDownloader, pinned by version and sha256. It authenticates with a real
# Steam account and downloads a depot by manifest gid — which anonymous SteamCMD
# cannot do. Baked (it is MIT-licensed tooling, not the game).
    curl -fsSL -o /tmp/dd.zip \
      "https://github.com/SteamRE/DepotDownloader/releases/download/DepotDownloader_${DEPOTDOWNLOADER_VERSION}/DepotDownloader-linux-x64.zip"; \
    echo "${DEPOTDOWNLOADER_SHA256}  /tmp/dd.zip" | sha256sum -c -; \
    mkdir -p /opt/depotdownloader; \
    unzip -q /tmp/dd.zip -d /opt/depotdownloader; \
    rm /tmp/dd.zip; \
    chmod +x /opt/depotdownloader/DepotDownloader; \
    chown -R chandlery:chandlery /opt/depotdownloader

RUN --mount=type=secret,id=extra-ca \
    if [ -s /run/secrets/extra-ca ]; then \
        cp /run/secrets/extra-ca /usr/local/share/ca-certificates/extra-ca.crt; \
        update-ca-certificates; \
    fi

COPY --from=probe /chandlery-a2s /usr/local/bin/chandlery-a2s
COPY --chmod=0755 fetch         /usr/local/lib/chandlery/fetch
COPY --chmod=0755 run           /usr/local/bin/valheim-server
COPY --chmod=0755 prepare       /usr/local/lib/chandlery/prepare
COPY --chmod=0755 stop-hook     /usr/local/lib/chandlery/stop
COPY --chmod=0755 health        /usr/local/lib/chandlery/health
COPY --chmod=0755 game-version  /usr/local/lib/chandlery/game-version

# The pin travels as environment: prepare fetches the gid, run locates it.
ENV VALHEIM_VERSION=${VALHEIM_VERSION} \
    VALHEIM_BUILD_ID=${VALHEIM_BUILD_ID} \
    VALHEIM_MANIFEST_GID=${VALHEIM_MANIFEST_GID} \
    VALHEIM_APP_ID=${VALHEIM_APP_ID} \
    VALHEIM_DEPOT_ID=${VALHEIM_DEPOT_ID}

USER chandlery
WORKDIR /data

# The tag is the game version; the Steam identifiers that actually address the
# bytes are recorded alongside it.
LABEL org.opencontainers.image.title="Valheim Dedicated Server" \
      org.opencontainers.image.version="${VALHEIM_VERSION}" \
      org.opencontainers.image.source="https://github.com/danielbodart/chandlery" \
      org.opencontainers.image.licenses="Apache-2.0" \
      dev.chandlery.valheim.build-id="${VALHEIM_BUILD_ID}" \
      dev.chandlery.valheim.manifest-gid="${VALHEIM_MANIFEST_GID}"

# 2456 is the game, 2457 the Steam query port. Valheim derives the second from
# the first and will not let you set them independently.
EXPOSE 2456/udp 2457/udp

# Loading a large world takes a while, and the first start fetches ~1.6 GB before
# that; a restart loop during either is how you corrupt a world.
HEALTHCHECK --interval=30s --timeout=10s --start-period=300s --retries=3 \
    CMD ["/usr/local/lib/chandlery/health"]

CMD ["/usr/local/bin/valheim-server"]
