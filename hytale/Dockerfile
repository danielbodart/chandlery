# syntax=docker/dockerfile:1
#
# Hytale Dedicated Server — baked, layered by churn.
#
# Built from the REPOSITORY ROOT (`docker build -f hytale/Dockerfile .`) so the
# shared build/ helpers are in context. The imperative work lives in named
# scripts: hytale/fetch resolves the entitled copy through the OAuth signing proxy
# (PLAN 7.1), verifies it, and unzips it — including Assets.zip, which is STORED
# (uncompressed) and which the server reads as a directory (--assets DIR_OR_ZIP),
# so unpacking it costs ~no size but lets its ~60k files bucket and dedupe.
# build/bake-layout then splits the server code (jar + AOT cache, the per-version
# delta) into its own top layer and buckets the rest.
#
# Baking redistributes Hytale's OAuth-gated assets (PLAN 7.1, 7.3) — accepted
# deliberately. The downloader access token is a BUILD SECRET (id=hytale-token,
# minted+rotated by tools/hytale-token); the image holds no credential, and the
# pin stays cryptographic (sha256-verified against the manifest, or HYTALE_SHA256).
#
# Running the server is still token passthrough: HYTALE_SERVER_SESSION_TOKEN and
# friends are injected by the deployer (or HYTALE_AUTH_MODE=offline). None baked.
ARG BASE=chandlery/base:test
ARG FETCH_BASE=debian:bookworm-slim
# Pinned: a floating 25-jre would drift the JRE under a tag meant to mean one
# exact thing. Temurin is Adoptium's OpenJDK.
ARG JAVA=eclipse-temurin:25.0.3_9-jre

FROM ${JAVA} AS java

# ---- fetch: resolve, download, verify, unzip, split, bucket, normalise ----
FROM ${FETCH_BASE} AS fetch

ARG HYTALE_VERSION
ARG HYTALE_PATCHLINE=release
ARG HYTALE_SHA256=
ARG SOURCE_DATE_EPOCH=0
ARG ASSET_BUCKETS=32

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl unzip jq \
 && rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 build/bucketize build/bake-layout hytale/fetch /usr/local/bin/
RUN --mount=type=secret,id=hytale-token,required=true fetch /stage
# The jar and its AOT cache change every build; give them their own top layer
# above the ~60k unzipped assets, which stay put.
RUN bake-layout /stage /buckets /bin-layer "${ASSET_BUCKETS}" "${SOURCE_DATE_EPOCH}" \
      Server/HytaleServer.jar Server/HytaleServer.aot.config

# ---- runtime: base + Java + baked layers + adapter ----
FROM ${BASE}

ARG HYTALE_VERSION
ARG HYTALE_PATCHLINE=release
ARG HYTALE_SHA256=

USER root

# Java 25, from Temurin. No curl/unzip/jq: the game is baked.
COPY --from=java /opt/java/openjdk /opt/java/openjdk
ENV JAVA_HOME=/opt/java/openjdk \
    PATH=/opt/java/openjdk/bin:/usr/local/bin:/usr/bin:/bin

# Asset buckets first: the lower, stable layers. Count MUST match ASSET_BUCKETS.
COPY --from=fetch --chown=chandlery:chandlery /buckets/00/ /opt/hytale/
COPY --from=fetch --chown=chandlery:chandlery /buckets/01/ /opt/hytale/
COPY --from=fetch --chown=chandlery:chandlery /buckets/02/ /opt/hytale/
COPY --from=fetch --chown=chandlery:chandlery /buckets/03/ /opt/hytale/
COPY --from=fetch --chown=chandlery:chandlery /buckets/04/ /opt/hytale/
COPY --from=fetch --chown=chandlery:chandlery /buckets/05/ /opt/hytale/
COPY --from=fetch --chown=chandlery:chandlery /buckets/06/ /opt/hytale/
COPY --from=fetch --chown=chandlery:chandlery /buckets/07/ /opt/hytale/
COPY --from=fetch --chown=chandlery:chandlery /buckets/08/ /opt/hytale/
COPY --from=fetch --chown=chandlery:chandlery /buckets/09/ /opt/hytale/
COPY --from=fetch --chown=chandlery:chandlery /buckets/10/ /opt/hytale/
COPY --from=fetch --chown=chandlery:chandlery /buckets/11/ /opt/hytale/
COPY --from=fetch --chown=chandlery:chandlery /buckets/12/ /opt/hytale/
COPY --from=fetch --chown=chandlery:chandlery /buckets/13/ /opt/hytale/
COPY --from=fetch --chown=chandlery:chandlery /buckets/14/ /opt/hytale/
COPY --from=fetch --chown=chandlery:chandlery /buckets/15/ /opt/hytale/
COPY --from=fetch --chown=chandlery:chandlery /buckets/16/ /opt/hytale/
COPY --from=fetch --chown=chandlery:chandlery /buckets/17/ /opt/hytale/
COPY --from=fetch --chown=chandlery:chandlery /buckets/18/ /opt/hytale/
COPY --from=fetch --chown=chandlery:chandlery /buckets/19/ /opt/hytale/
COPY --from=fetch --chown=chandlery:chandlery /buckets/20/ /opt/hytale/
COPY --from=fetch --chown=chandlery:chandlery /buckets/21/ /opt/hytale/
COPY --from=fetch --chown=chandlery:chandlery /buckets/22/ /opt/hytale/
COPY --from=fetch --chown=chandlery:chandlery /buckets/23/ /opt/hytale/
COPY --from=fetch --chown=chandlery:chandlery /buckets/24/ /opt/hytale/
COPY --from=fetch --chown=chandlery:chandlery /buckets/25/ /opt/hytale/
COPY --from=fetch --chown=chandlery:chandlery /buckets/26/ /opt/hytale/
COPY --from=fetch --chown=chandlery:chandlery /buckets/27/ /opt/hytale/
COPY --from=fetch --chown=chandlery:chandlery /buckets/28/ /opt/hytale/
COPY --from=fetch --chown=chandlery:chandlery /buckets/29/ /opt/hytale/
COPY --from=fetch --chown=chandlery:chandlery /buckets/30/ /opt/hytale/
COPY --from=fetch --chown=chandlery:chandlery /buckets/31/ /opt/hytale/
COPY --chmod=0755 hytale/prepare   /usr/local/lib/chandlery/prepare
COPY --chmod=0755 hytale/stop-hook /usr/local/lib/chandlery/stop
COPY --chmod=0755 hytale/run       /usr/local/bin/hytale-server
# The server code last: the top layer, the per-build delta (jar + AOT cache).
COPY --from=fetch --chown=chandlery:chandlery /bin-layer/Server/ /opt/hytale/Server/

ENV HYTALE_VERSION=${HYTALE_VERSION} \
    HYTALE_PATCHLINE=${HYTALE_PATCHLINE} \
    HYTALE_SHA256=${HYTALE_SHA256}

# The server ships an hourly auto-updater that would rewrite its own binaries out
# from under the tag (PLAN 7.1); it stays off — CI and the deployer do that job.
ENV HYTALE_DISABLE_UPDATES=1

USER chandlery
WORKDIR /data

LABEL org.opencontainers.image.title="Hytale Dedicated Server" \
      org.opencontainers.image.version="${HYTALE_VERSION}" \
      org.opencontainers.image.source="https://github.com/danielbodart/chandlery" \
      org.opencontainers.image.licenses="Apache-2.0"

# QUIC over UDP, 5520 by default. No HEALTHCHECK: no in-box protocol probe
# (PLAN 7.1), and a port-bound check is what the deployer already does, better.
EXPOSE 5520/udp

CMD ["/usr/local/bin/hytale-server"]
