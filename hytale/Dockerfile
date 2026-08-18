# syntax=docker/dockerfile:1
#
# Hytale Dedicated Server — baked, layered by churn.
#
# The build resolves the operator's entitled copy through Hytale's OAuth signing
# proxy and bakes it. As with Bedrock and Valheim the payload is split across
# ASSET_BUCKETS COPY layers by a stable hash of each file's depth-2 subtree
# (bucketize), every mtime normalised to SOURCE_DATE_EPOCH — which matters most
# here: Assets.zip is ~3.3 GB and changes rarely, so as a top-level file it gets
# its own bucket layer that dedupes wholesale across versions while the jar and
# config churn in their own small buckets. A rollback is `docker pull <old tag>`;
# its 3.3 GB Assets bucket is already local.
#
# Baking redistributes Hytale, whose every asset is gated behind per-account
# OAuth and a signed URL (PLAN 7.1) — this image is for a PRIVATE registry. The
# fetch needs a downloader *access* token: mint it on the host with
# tools/hytale-token (it refreshes and rotates) and pass it as a BUILD SECRET
# (id=hytale-token). The image holds no credential; the pin stays cryptographic
# (sha256-verified against the manifest, or HYTALE_SHA256 if given).
#
# Running the server is still token passthrough: the deployer injects
# HYTALE_SERVER_SESSION_TOKEN and HYTALE_SERVER_IDENTITY_TOKEN at runtime (or
# HYTALE_AUTH_MODE=offline for LAN/tests). None are baked.
ARG BASE=chandlery/base:test
ARG FETCH_BASE=debian:bookworm-slim
# Pinned, like everything else here: a floating 25-jre would drift the JRE under
# a tag that is supposed to mean one exact thing. Temurin is Adoptium's OpenJDK.
ARG JAVA=eclipse-temurin:25.0.3_9-jre

FROM ${JAVA} AS java

# ---- fetch: OAuth signed-URL resolve, download, verify, bucket, normalise ----
FROM ${FETCH_BASE} AS fetch

ARG HYTALE_VERSION
ARG HYTALE_PATCHLINE=release
ARG HYTALE_SHA256=
ARG SOURCE_DATE_EPOCH=0
ARG ASSET_BUCKETS=16

COPY --chmod=0755 bucketize /usr/local/bin/bucketize

RUN set -eux; \
    test -n "${HYTALE_VERSION}" || { echo "HYTALE_VERSION build-arg is required" >&2; exit 64; }; \
    apt-get update; \
# jq parses the version manifest and signed-URL responses; curl/unzip fetch and
# unpack. None of this rides into the runtime image.
    apt-get install -y --no-install-recommends ca-certificates curl unzip jq; \
    rm -rf /var/lib/apt/lists/*

# The authenticated fetch. Token mounted, never baked. Flow (PLAN 7.1): a signed
# URL for the version manifest -> {version,download_url,sha256} -> a signed URL
# for the build -> the zip. Fail closed if the patchline has moved off the pinned
# version, or the sha256 does not match.
RUN --mount=type=secret,id=hytale-token,required=true set -eux; \
    token=$(cat /run/secrets/hytale-token); \
    api="${HYTALE_ACCOUNT_API:-https://account-data.hytale.com}"; \
    signed_url() { curl -fsS -A chandlery/hytale -H "authorization: Bearer $token" "$api/game-assets/$1" | jq -r '.url // empty'; }; \
    vsig=$(signed_url "version/${HYTALE_PATCHLINE}.json"); \
    test -n "$vsig" || { echo "no signed URL for the version manifest (token expired?)" >&2; exit 65; }; \
    meta=$(curl -fsS "$vsig"); \
    got_version=$(printf '%s' "$meta" | jq -r '.version // empty'); \
    download_url=$(printf '%s' "$meta" | jq -r '.download_url // empty'); \
    manifest_sha=$(printf '%s' "$meta" | jq -r '.sha256 // empty'); \
    if [ -n "$got_version" ] && [ "$got_version" != "${HYTALE_VERSION}" ]; then \
        echo "ERROR: ${HYTALE_PATCHLINE} is on $got_version, but this image pins ${HYTALE_VERSION}" >&2; exit 65; \
    fi; \
    test -n "$download_url" || { echo "no download_url in the version manifest" >&2; exit 65; }; \
    bsig=$(signed_url "$download_url"); \
    test -n "$bsig" || { echo "no signed URL for the build" >&2; exit 65; }; \
    curl -fsSL -A chandlery/hytale --retry 5 --retry-all-errors --retry-max-time 3600 -o /tmp/hytale.zip "$bsig"; \
    want="${HYTALE_SHA256:-$manifest_sha}"; \
    if [ -n "$want" ] && [ "$want" != null ]; then \
        echo "verifying sha256" >&2; \
        echo "$want  /tmp/hytale.zip" | sha256sum -c -; \
    else \
        echo "WARNING: no sha256 to verify against" >&2; \
    fi; \
    mkdir -p /stage; \
    unzip -q /tmp/hytale.zip -d /stage; \
    rm -f /tmp/hytale.zip; \
    find /stage -maxdepth 2 -name '*.jar' | grep -q . || { echo "no server jar in the download" >&2; exit 65; }

RUN set -eux; \
# Bucket the whole payload. Assets.zip is a top-level file, so it becomes its own
# bucket layer — exactly the large-stable-asset isolation §7.2 wanted.
    bucketize /stage /buckets "${ASSET_BUCKETS}"; \
    rm -rf /stage; \
    find /buckets -exec touch --no-dereference -h -d "@${SOURCE_DATE_EPOCH}" {} +

# ---- runtime: base + Java + baked buckets + adapter ----
FROM ${BASE}

ARG HYTALE_VERSION
ARG HYTALE_PATCHLINE=release
ARG HYTALE_SHA256=

USER root

# Java 25, from Temurin. No curl/unzip/jq: the game is baked, so the fetch
# tooling does not ride into the runtime image.
COPY --from=java /opt/java/openjdk /opt/java/openjdk
ENV JAVA_HOME=/opt/java/openjdk \
    PATH=/opt/java/openjdk/bin:/usr/local/bin:/usr/bin:/bin

# Asset buckets first: the lower, stable layers (Assets.zip's bucket dedupes
# wholesale across versions). The count MUST match ASSET_BUCKETS in the fetch stage.
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
COPY --chmod=0755 prepare   /usr/local/lib/chandlery/prepare
COPY --chmod=0755 stop-hook /usr/local/lib/chandlery/stop
COPY --chmod=0755 run       /usr/local/bin/hytale-server

# The pin travels as environment; run locates the baked game.
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

# QUIC over UDP, 5520 by default (--bind). No HEALTHCHECK: no protocol probe
# ships in the box (PLAN 7.1), and a port-bound check is what the deployer
# already does, better, from outside.
EXPOSE 5520/udp

CMD ["/usr/local/bin/hytale-server"]
