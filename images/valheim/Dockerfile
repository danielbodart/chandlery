# syntax=docker/dockerfile:1
#
# Valheim Dedicated Server — baked, layered by churn.
#
# Built from the REPOSITORY ROOT (`docker build -f images/valheim/Dockerfile .`) so the
# shared build/ helpers are in context. The imperative work lives in named
# scripts: images/valheim/fetch authenticates with the operator's licensed Steam account
# and downloads exactly the pinned depot manifest (plus a current steamclient.so);
# build/bake-layout buckets the tree by subtree hash and normalises mtimes. So an
# unchanged subtree bakes to a byte-identical layer the registry dedupes across
# versions, and a rollback is `docker pull <old tag>`.
#
# Unlike Bedrock and Hytale, no binary is split into its own layer: valheim's
# real per-version churn is the Managed DLLs (already their own bucket), and the
# valheim_server.x86_64 launcher is a 28 KB stub — splitting it would isolate the
# wrong file and save nothing.
#
# Baking redistributes Valheim, against the Steam Subscriber Agreement (PLAN 7.3)
# — accepted deliberately. The pin stays exact: fetch pulls one immutable manifest
# gid. The account.config token is a BUILD SECRET (id=steam-token), the username a
# build-arg; neither rides into the image, which carries no fetch machinery.
ARG BASE=chandlery/base:test
ARG FETCH_BASE=debian:bookworm-slim
ARG DEPOTDOWNLOADER_VERSION=3.4.0
ARG DEPOTDOWNLOADER_SHA256=a999dec66b4850fc961bd50366696d23c2d0fad7b18790e6a5647b2f19097a53

FROM golang:1.24-bookworm AS probe
WORKDIR /src
COPY images/valheim/probe/go.mod images/valheim/probe/main.go images/valheim/probe/main_test.go ./
# The health check decides whether a live server gets replaced, so its tests run
# as part of building it.
RUN CGO_ENABLED=0 go test ./... && CGO_ENABLED=0 go build -trimpath -o /chandlery-a2s .

# ---- fetch: authenticate, download the pinned manifest, split, bucket, normalise ----
FROM ${FETCH_BASE} AS fetch

ARG VALHEIM_MANIFEST_GID
ARG VALHEIM_APP_ID=896660
ARG VALHEIM_DEPOT_ID=896661
ARG STEAM_USERNAME
ARG DEPOTDOWNLOADER_VERSION
ARG DEPOTDOWNLOADER_SHA256
ARG SOURCE_DATE_EPOCH=0
ARG ASSET_BUCKETS=32

# ca-certificates + libicu for DepotDownloader (self-contained .NET); lib32gcc-s1
# for SteamCMD (32-bit), which supplies the current steamclient.so.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl unzip libicu72 lib32gcc-s1 \
 && rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 build/bucketize build/bake-layout images/valheim/fetch /usr/local/bin/
RUN --mount=type=secret,id=steam-token,required=true fetch /stage
# No binary split (see header): the whole tree buckets by subtree, depth 2.
RUN bake-layout /stage /buckets /bin-layer "${ASSET_BUCKETS}" "${SOURCE_DATE_EPOCH}" 2

# ---- runtime: base + health probe + baked layers + adapter ----
FROM ${BASE}

ARG VALHEIM_VERSION=dev
ARG VALHEIM_BUILD_ID
ARG VALHEIM_MANIFEST_GID
ARG VALHEIM_APP_ID=896660
ARG VALHEIM_DEPOT_ID=896661
# Our packaging revision (the repo's git SHA) — see images/bedrock/Dockerfile.
ARG CHANDLERY_REVISION=

USER root
# The Valheim server's own runtime deps (per Iron Gate's image). No SteamCMD,
# DepotDownloader, curl or unzip — the game is baked.
RUN test -n "${VALHEIM_BUILD_ID}"     || { echo "VALHEIM_BUILD_ID build-arg is required" >&2; exit 64; }; \
    test -n "${VALHEIM_MANIFEST_GID}" || { echo "VALHEIM_MANIFEST_GID build-arg is required" >&2; exit 64; }; \
    apt-get update \
 && apt-get install -y --no-install-recommends libatomic1 libpulse0 \
 && rm -rf /var/lib/apt/lists/*

COPY --from=probe /chandlery-a2s /usr/local/bin/chandlery-a2s
# Asset buckets first: the lower, stable layers. Count MUST match ASSET_BUCKETS.
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
COPY --chmod=0755 images/valheim/run           /usr/local/bin/valheim-server
COPY --chmod=0755 images/valheim/prepare       /usr/local/lib/chandlery/prepare
COPY --chmod=0755 images/valheim/stop-hook     /usr/local/lib/chandlery/stop
COPY --chmod=0755 images/valheim/health        /usr/local/lib/chandlery/health
COPY --chmod=0755 images/valheim/game-version  /usr/local/lib/chandlery/game-version

ENV VALHEIM_VERSION=${VALHEIM_VERSION} \
    VALHEIM_BUILD_ID=${VALHEIM_BUILD_ID} \
    VALHEIM_MANIFEST_GID=${VALHEIM_MANIFEST_GID} \
    VALHEIM_APP_ID=${VALHEIM_APP_ID} \
    VALHEIM_DEPOT_ID=${VALHEIM_DEPOT_ID}

USER chandlery
WORKDIR /data

LABEL org.opencontainers.image.title="Valheim Dedicated Server" \
      org.opencontainers.image.version="${VALHEIM_VERSION}" \
      org.opencontainers.image.revision="${CHANDLERY_REVISION}" \
      org.opencontainers.image.source="https://github.com/danielbodart/chandlery" \
      org.opencontainers.image.licenses="Apache-2.0" \
      dev.chandlery.valheim.build-id="${VALHEIM_BUILD_ID}" \
      dev.chandlery.valheim.manifest-gid="${VALHEIM_MANIFEST_GID}"

# 2456 is the game, 2457 the Steam query port. Valheim derives the second from
# the first and will not let you set them independently.
EXPOSE 2456/udp 2457/udp

HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
    CMD ["/usr/local/lib/chandlery/health"]

CMD ["/usr/local/bin/valheim-server"]
