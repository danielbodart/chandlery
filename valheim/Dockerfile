# syntax=docker/dockerfile:1
#
# Valheim Dedicated Server — baked, layered by churn.
#
# The build fetches exactly the pinned depot manifest with DepotDownloader and
# bakes it. As with Bedrock (bedrock/Dockerfile) the game tree is split across
# ASSET_BUCKETS COPY layers by a stable hash of each file's depth-2 subtree
# (bucketize), every mtime normalised to SOURCE_DATE_EPOCH, so an unchanged
# subtree bakes to a byte-identical layer the registry dedupes across versions
# and a bump re-pulls only what actually changed. A rollback is `docker pull
# <old tag>`: its unchanged buckets are already local.
#
# Baking redistributes Valheim, against the Steam Subscriber Agreement (PLAN 7.3)
# — accepted here deliberately for the value it buys. The pin stays exact:
# DepotDownloader fetches one immutable manifest gid, so the baked layers cannot
# be any build but the one on the tag.
#
# The fetch authenticates with the operator's own licensed Steam account (the
# depot is not anonymous-downloadable): the account.config token is a BUILD
# SECRET (id=steam-token), the username a build-arg — neither rides into the
# image. steamclient.so is refreshed from SteamCMD at build (the depot's is too
# old for the server's Steam init) and baked; a rebuild refreshes it if it ages.
ARG BASE=chandlery/base:test
ARG FETCH_BASE=debian:bookworm-slim
ARG DEPOTDOWNLOADER_VERSION=3.4.0
ARG DEPOTDOWNLOADER_SHA256=a999dec66b4850fc961bd50366696d23c2d0fad7b18790e6a5647b2f19097a53

FROM golang:1.24-bookworm AS probe
WORKDIR /src
COPY probe/go.mod probe/main.go probe/main_test.go ./
# The health check decides whether a live server gets replaced, so its tests run
# as part of building it.
RUN CGO_ENABLED=0 go test ./... && CGO_ENABLED=0 go build -trimpath -o /chandlery-a2s .

# ---- fetch: authenticate, download the pinned manifest, split, bucket, normalise ----
FROM ${FETCH_BASE} AS fetch

# No defaults for the identifiers: building "some build of Valheim" is the thing
# this project exists to prevent (see bedrock/Dockerfile).
ARG VALHEIM_MANIFEST_GID
ARG VALHEIM_APP_ID=896660
ARG VALHEIM_DEPOT_ID=896661
# The licensed account's username. Not a secret; the token is (mounted below).
ARG STEAM_USERNAME
ARG DEPOTDOWNLOADER_VERSION
ARG DEPOTDOWNLOADER_SHA256
ARG SOURCE_DATE_EPOCH=0
ARG ASSET_BUCKETS=32

COPY --chmod=0755 bucketize /usr/local/bin/bucketize

RUN set -eux; \
    test -n "${VALHEIM_MANIFEST_GID}" || { echo "VALHEIM_MANIFEST_GID build-arg is required" >&2; exit 64; }; \
    test -n "${STEAM_USERNAME}"       || { echo "STEAM_USERNAME build-arg is required" >&2; exit 64; }; \
    apt-get update; \
# ca-certificates + libicu for DepotDownloader (self-contained .NET); lib32gcc-s1
# for SteamCMD (32-bit), which supplies a current steamclient.so.
    apt-get install -y --no-install-recommends \
        ca-certificates curl unzip libicu72 lib32gcc-s1; \
    rm -rf /var/lib/apt/lists/*; \
# DepotDownloader, pinned by version + sha256 (MIT tooling, not the game).
    curl -fsSL -o /tmp/dd.zip \
      "https://github.com/SteamRE/DepotDownloader/releases/download/DepotDownloader_${DEPOTDOWNLOADER_VERSION}/DepotDownloader-linux-x64.zip"; \
    echo "${DEPOTDOWNLOADER_SHA256}  /tmp/dd.zip" | sha256sum -c -; \
    mkdir -p /opt/depotdownloader; \
    unzip -q /tmp/dd.zip -d /opt/depotdownloader; \
    chmod +x /opt/depotdownloader/DepotDownloader; \
    rm /tmp/dd.zip

# The authenticated fetch. The token is mounted, never baked; DepotDownloader
# keeps its credential in .NET IsolatedStorage under $HOME, so we init the store
# anonymously, drop the operator's token into it, then run authenticated with no
# 2FA prompt — the same dance the old runtime fetch did, moved to build time.
RUN --mount=type=secret,id=steam-token,required=true set -eux; \
    DD=/opt/depotdownloader/DepotDownloader; \
    export HOME=/tmp/dd-home; mkdir -p "$HOME"; \
    "$DD" -app "${VALHEIM_APP_ID}" -manifest-only >/dev/null 2>&1 || true; \
    ass=$(find "$HOME" -type d -name AssemFiles | head -1); \
    test -n "$ass" || { echo "DepotDownloader did not init its credential store" >&2; exit 70; }; \
    cp /run/secrets/steam-token "$ass/account.config"; \
    "$DD" -app "${VALHEIM_APP_ID}" -depot "${VALHEIM_DEPOT_ID}" -manifest "${VALHEIM_MANIFEST_GID}" \
          -username "${STEAM_USERNAME}" -remember-password -dir /dl; \
# Relocate the server up out of DepotDownloader's layout into /stage, dropping
# its .DepotDownloader bookkeeping.
    found=$(find /dl -type f -name valheim_server.x86_64 | head -1); \
    test -n "$found" || { echo "no valheim_server.x86_64 in the download" >&2; exit 65; }; \
    mkdir -p /stage; \
    (cd "$(dirname "$found")" && tar cf - --exclude='.DepotDownloader' .) | (cd /stage && tar xf -); \
    chmod +x /stage/valheim_server.x86_64; \
    rm -rf /dl "$HOME"

# A current steamclient.so from SteamCMD, baked next to the server. The depot's
# own is from 2022 and the server's Steam init rejects it ("Missing interface
# adapter for SteamGameServer015"); SteamCMD self-updates to a current one.
RUN set -eux; \
    mkdir -p /opt/steamcmd; \
    curl -fsSL --http1.1 --retry 5 --retry-all-errors \
         https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
      | tar -xz -C /opt/steamcmd; \
    /opt/steamcmd/steamcmd.sh +quit >/dev/null 2>&1 || true; \
# The server is 64-bit, so it must be the linux64 library — a bare `find | head`
# can pick linux32 first (filesystem order), and the 64-bit server then fails its
# Steam init with "Steam is not initialized".
    sc=$(find /opt/steamcmd -path '*/linux64/*' -name steamclient.so | head -1); \
    [ -n "$sc" ] || sc=$(find /opt/steamcmd -name steamclient.so | head -1); \
    test -n "$sc" || { echo "SteamCMD produced no steamclient.so" >&2; exit 70; }; \
    cp "$sc" /stage/steamclient.so

RUN set -eux; \
# Split the server binary into its own top layer — like Bedrock's bedrock_server,
# it changes every build while the asset tree around it does not, so it should not
# sit in a bucket that would drag its frozen neighbours on every bump. The rest of
# the tree (DLLs, asset bundles) buckets by subtree. Then normalise every mtime.
    mkdir -p /bin-layer; \
    mv /stage/valheim_server.x86_64 /bin-layer/valheim_server.x86_64; \
    bucketize /stage /buckets "${ASSET_BUCKETS}"; \
    rm -rf /stage; \
    find /buckets /bin-layer -exec touch --no-dereference -h -d "@${SOURCE_DATE_EPOCH}" {} +

# ---- runtime: base + health probe + baked buckets + adapter ----
FROM ${BASE}

ARG VALHEIM_VERSION
ARG VALHEIM_BUILD_ID
ARG VALHEIM_MANIFEST_GID
ARG VALHEIM_APP_ID=896660
ARG VALHEIM_DEPOT_ID=896661

USER root
RUN set -eux; \
    test -n "${VALHEIM_VERSION}"      || { echo "VALHEIM_VERSION build-arg is required" >&2; exit 64; }; \
    test -n "${VALHEIM_BUILD_ID}"     || { echo "VALHEIM_BUILD_ID build-arg is required" >&2; exit 64; }; \
    test -n "${VALHEIM_MANIFEST_GID}" || { echo "VALHEIM_MANIFEST_GID build-arg is required" >&2; exit 64; }; \
    apt-get update; \
# The Valheim server's own runtime deps (per Iron Gate's image). No SteamCMD,
# DepotDownloader, curl, unzip or libicu here: the game is baked, so none of the
# fetch machinery rides into the runtime image.
    apt-get install -y --no-install-recommends libatomic1 libpulse0; \
    rm -rf /var/lib/apt/lists/*

COPY --from=probe /chandlery-a2s /usr/local/bin/chandlery-a2s
# Asset buckets first: the lower, stable layers that dedupe across versions. The
# count MUST match ASSET_BUCKETS in the fetch stage.
COPY --from=fetch --chown=chandlery:chandlery /buckets/00/ /opt/valheim/
COPY --from=fetch --chown=chandlery:chandlery /buckets/01/ /opt/valheim/
COPY --from=fetch --chown=chandlery:chandlery /buckets/02/ /opt/valheim/
COPY --from=fetch --chown=chandlery:chandlery /buckets/03/ /opt/valheim/
COPY --from=fetch --chown=chandlery:chandlery /buckets/04/ /opt/valheim/
COPY --from=fetch --chown=chandlery:chandlery /buckets/05/ /opt/valheim/
COPY --from=fetch --chown=chandlery:chandlery /buckets/06/ /opt/valheim/
COPY --from=fetch --chown=chandlery:chandlery /buckets/07/ /opt/valheim/
COPY --from=fetch --chown=chandlery:chandlery /buckets/08/ /opt/valheim/
COPY --from=fetch --chown=chandlery:chandlery /buckets/09/ /opt/valheim/
COPY --from=fetch --chown=chandlery:chandlery /buckets/10/ /opt/valheim/
COPY --from=fetch --chown=chandlery:chandlery /buckets/11/ /opt/valheim/
COPY --from=fetch --chown=chandlery:chandlery /buckets/12/ /opt/valheim/
COPY --from=fetch --chown=chandlery:chandlery /buckets/13/ /opt/valheim/
COPY --from=fetch --chown=chandlery:chandlery /buckets/14/ /opt/valheim/
COPY --from=fetch --chown=chandlery:chandlery /buckets/15/ /opt/valheim/
COPY --from=fetch --chown=chandlery:chandlery /buckets/16/ /opt/valheim/
COPY --from=fetch --chown=chandlery:chandlery /buckets/17/ /opt/valheim/
COPY --from=fetch --chown=chandlery:chandlery /buckets/18/ /opt/valheim/
COPY --from=fetch --chown=chandlery:chandlery /buckets/19/ /opt/valheim/
COPY --from=fetch --chown=chandlery:chandlery /buckets/20/ /opt/valheim/
COPY --from=fetch --chown=chandlery:chandlery /buckets/21/ /opt/valheim/
COPY --from=fetch --chown=chandlery:chandlery /buckets/22/ /opt/valheim/
COPY --from=fetch --chown=chandlery:chandlery /buckets/23/ /opt/valheim/
COPY --from=fetch --chown=chandlery:chandlery /buckets/24/ /opt/valheim/
COPY --from=fetch --chown=chandlery:chandlery /buckets/25/ /opt/valheim/
COPY --from=fetch --chown=chandlery:chandlery /buckets/26/ /opt/valheim/
COPY --from=fetch --chown=chandlery:chandlery /buckets/27/ /opt/valheim/
COPY --from=fetch --chown=chandlery:chandlery /buckets/28/ /opt/valheim/
COPY --from=fetch --chown=chandlery:chandlery /buckets/29/ /opt/valheim/
COPY --from=fetch --chown=chandlery:chandlery /buckets/30/ /opt/valheim/
COPY --from=fetch --chown=chandlery:chandlery /buckets/31/ /opt/valheim/
COPY --chmod=0755 run           /usr/local/bin/valheim-server
COPY --chmod=0755 prepare       /usr/local/lib/chandlery/prepare
COPY --chmod=0755 stop-hook     /usr/local/lib/chandlery/stop
COPY --chmod=0755 health        /usr/local/lib/chandlery/health
COPY --chmod=0755 game-version  /usr/local/lib/chandlery/game-version
# The server binary last: the top layer, and the per-build delta. It changes
# every version while everything below it does not.
COPY --from=fetch --chown=chandlery:chandlery /bin-layer/valheim_server.x86_64 /opt/valheim/valheim_server.x86_64

# The pin travels as environment: run locates the baked game, health reports it.
ENV VALHEIM_VERSION=${VALHEIM_VERSION} \
    VALHEIM_BUILD_ID=${VALHEIM_BUILD_ID} \
    VALHEIM_MANIFEST_GID=${VALHEIM_MANIFEST_GID} \
    VALHEIM_APP_ID=${VALHEIM_APP_ID} \
    VALHEIM_DEPOT_ID=${VALHEIM_DEPOT_ID}

USER chandlery
WORKDIR /data

LABEL org.opencontainers.image.title="Valheim Dedicated Server" \
      org.opencontainers.image.version="${VALHEIM_VERSION}" \
      org.opencontainers.image.source="https://github.com/danielbodart/chandlery" \
      org.opencontainers.image.licenses="Apache-2.0" \
      dev.chandlery.valheim.build-id="${VALHEIM_BUILD_ID}" \
      dev.chandlery.valheim.manifest-gid="${VALHEIM_MANIFEST_GID}"

# 2456 is the game, 2457 the Steam query port. Valheim derives the second from
# the first and will not let you set them independently.
EXPOSE 2456/udp 2457/udp

# Loading a large world takes a while; no first-run fetch to wait on any more.
HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
    CMD ["/usr/local/lib/chandlery/health"]

CMD ["/usr/local/bin/valheim-server"]
