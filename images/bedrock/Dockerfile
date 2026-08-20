# syntax=docker/dockerfile:1
#
# Minecraft Bedrock Dedicated Server — baked, layered by churn.
#
# Built from the REPOSITORY ROOT so the shared build helpers in build/ are in
# context: `docker build -f images/bedrock/Dockerfile .`. The imperative work lives in
# named scripts (images/bedrock/fetch downloads+verifies; build/bake-layout splits the
# binary out, buckets the assets and normalises mtimes; build/bucketize is the
# bucketer) so this file stays structure, not shell.
#
# The layering is measured (tools/release-diff over 1.26.42.1 -> .43.1 -> .44.3):
# bedrock_server is the whole per-release delta, so it gets its own top layer; the
# ~24 MB asset tree barely moves, so it is split across ASSET_BUCKETS subtree-hash
# layers with mtimes normalised — an unchanged subtree then bakes to a byte-
# identical layer the registry dedupes, and a bump re-pulls only the changed
# buckets plus the binary (measured: 76.9 MB of a 137 MB image, 20/29 layers
# shared across .43.1 <-> .44.3). A rollback is `docker pull <old tag>`.
#
# Baking redistributes BDS, which the Minecraft EULA forbids (PLAN 7.3) — accepted
# here deliberately for the value it buys. The pin stays cryptographic: fetch
# verifies BEDROCK_SHA256 before baking, so the build fails closed on wrong bytes.
ARG BASE=chandlery/base:test
ARG MC_MONITOR=itzg/mc-monitor:latest
ARG FETCH_BASE=debian:bookworm-slim

FROM ${MC_MONITOR} AS mc-monitor

# ---- fetch: download, verify, split, bucket, normalise. Nothing here ships. ----
FROM ${FETCH_BASE} AS fetch

# No default: building "some version of Bedrock" is exactly what this project
# exists to stop. CI passes what Mojang currently ships, with its sha256.
ARG BEDROCK_VERSION
ARG BEDROCK_SHA256=
ARG BEDROCK_URL=
# The fixed mtime every baked file gets, so unchanged buckets dedupe across
# versions (SOURCE_DATE_EPOCH is the reproducible-build convention; 0 = 1970).
ARG SOURCE_DATE_EPOCH=0
# The number of asset-bucket layers. Kept in lockstep with the COPY lines below.
ARG ASSET_BUCKETS=32

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl unzip \
 && rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 build/bucketize build/bake-layout images/bedrock/fetch /usr/local/bin/
RUN fetch /stage
# depth 2: Bedrock's churn clusters at depth-2 (per-pack, version-named dirs).
RUN bake-layout /stage /buckets /bin-layer "${ASSET_BUCKETS}" "${SOURCE_DATE_EPOCH}" 2 bedrock_server

# ---- runtime: base + monitor + baked layers + adapter ----
FROM ${BASE}

ARG BEDROCK_VERSION
# Our packaging revision (the repo's git SHA). The image version label stays the
# game version; this records which build definition produced the image, so tags
# and `docker inspect` can tell two builds of the same game version apart.
ARG CHANDLERY_REVISION=

USER root

COPY --from=mc-monitor /mc-monitor /usr/local/bin/mc-monitor
# Asset buckets first: the lower, stable layers. Each is its own COPY so an
# unchanged bucket keeps its digest and is not re-pulled. The count MUST match
# ASSET_BUCKETS in the fetch stage.
COPY --from=fetch --chown=chandlery:chandlery /buckets/00/ /opt/bedrock/
COPY --from=fetch --chown=chandlery:chandlery /buckets/01/ /opt/bedrock/
COPY --from=fetch --chown=chandlery:chandlery /buckets/02/ /opt/bedrock/
COPY --from=fetch --chown=chandlery:chandlery /buckets/03/ /opt/bedrock/
COPY --from=fetch --chown=chandlery:chandlery /buckets/04/ /opt/bedrock/
COPY --from=fetch --chown=chandlery:chandlery /buckets/05/ /opt/bedrock/
COPY --from=fetch --chown=chandlery:chandlery /buckets/06/ /opt/bedrock/
COPY --from=fetch --chown=chandlery:chandlery /buckets/07/ /opt/bedrock/
COPY --from=fetch --chown=chandlery:chandlery /buckets/08/ /opt/bedrock/
COPY --from=fetch --chown=chandlery:chandlery /buckets/09/ /opt/bedrock/
COPY --from=fetch --chown=chandlery:chandlery /buckets/10/ /opt/bedrock/
COPY --from=fetch --chown=chandlery:chandlery /buckets/11/ /opt/bedrock/
COPY --from=fetch --chown=chandlery:chandlery /buckets/12/ /opt/bedrock/
COPY --from=fetch --chown=chandlery:chandlery /buckets/13/ /opt/bedrock/
COPY --from=fetch --chown=chandlery:chandlery /buckets/14/ /opt/bedrock/
COPY --from=fetch --chown=chandlery:chandlery /buckets/15/ /opt/bedrock/
COPY --from=fetch --chown=chandlery:chandlery /buckets/16/ /opt/bedrock/
COPY --from=fetch --chown=chandlery:chandlery /buckets/17/ /opt/bedrock/
COPY --from=fetch --chown=chandlery:chandlery /buckets/18/ /opt/bedrock/
COPY --from=fetch --chown=chandlery:chandlery /buckets/19/ /opt/bedrock/
COPY --from=fetch --chown=chandlery:chandlery /buckets/20/ /opt/bedrock/
COPY --from=fetch --chown=chandlery:chandlery /buckets/21/ /opt/bedrock/
COPY --from=fetch --chown=chandlery:chandlery /buckets/22/ /opt/bedrock/
COPY --from=fetch --chown=chandlery:chandlery /buckets/23/ /opt/bedrock/
COPY --from=fetch --chown=chandlery:chandlery /buckets/24/ /opt/bedrock/
COPY --from=fetch --chown=chandlery:chandlery /buckets/25/ /opt/bedrock/
COPY --from=fetch --chown=chandlery:chandlery /buckets/26/ /opt/bedrock/
COPY --from=fetch --chown=chandlery:chandlery /buckets/27/ /opt/bedrock/
COPY --from=fetch --chown=chandlery:chandlery /buckets/28/ /opt/bedrock/
COPY --from=fetch --chown=chandlery:chandlery /buckets/29/ /opt/bedrock/
COPY --from=fetch --chown=chandlery:chandlery /buckets/30/ /opt/bedrock/
COPY --from=fetch --chown=chandlery:chandlery /buckets/31/ /opt/bedrock/
COPY --chmod=0755 images/bedrock/prepare   /usr/local/lib/chandlery/prepare
COPY --chmod=0755 images/bedrock/stop-hook /usr/local/lib/chandlery/stop
COPY --chmod=0755 images/bedrock/health    /usr/local/lib/chandlery/health
COPY --chmod=0755 images/bedrock/run       /usr/local/bin/bedrock-server
# Binary last: the top layer, and the whole per-release delta.
COPY --from=fetch --chown=chandlery:chandlery /bin-layer/bedrock_server /opt/bedrock/bedrock_server

# The version travels as environment so prepare and run both see it.
ENV BEDROCK_VERSION=${BEDROCK_VERSION}

USER chandlery
WORKDIR /data

# BDS is x86-64 only; there is no ARM build to fall back to.
LABEL org.opencontainers.image.title="Minecraft Bedrock Dedicated Server" \
      org.opencontainers.image.version="${BEDROCK_VERSION}" \
      org.opencontainers.image.revision="${CHANDLERY_REVISION}" \
      org.opencontainers.image.source="https://github.com/danielbodart/chandlery" \
      org.opencontainers.image.licenses="Apache-2.0"

# 19132/udp is the game; 19133/udp is the IPv6 socket BDS insists on binding.
EXPOSE 19132/udp 19133/udp

# A protocol probe, not a port check: it proves the server answers players.
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD ["/usr/local/lib/chandlery/health"]

CMD ["/usr/local/bin/bedrock-server"]
