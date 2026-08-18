# syntax=docker/dockerfile:1
#
# Minecraft Bedrock Dedicated Server — baked, layered by churn.
#
# The image carries the exact server it names. The layering is measured, not
# guessed (tools/release-diff over 1.26.42.1 -> .43.1 -> .44.3):
#
#   * bedrock_server is the WHOLE delta between releases — the binary changes,
#     the ~9,900 asset files do not. So it sits in its own top layer (~74 MB
#     compressed); that layer, and only that layer, is what a version bump must
#     pull in full.
#   * the asset tree (behavior/resource packs, ~24 MB) is split across ASSET_BUCKETS
#     COPY layers by a stable hash of each file's depth-2 subtree (see bucketize),
#     with every mtime normalised to SOURCE_DATE_EPOCH. An unchanged subtree bakes
#     to a byte-identical bucket layer every release, so the registry dedupes it
#     and a bump re-pulls only the few buckets that actually changed (measured
#     1.26.43.1 -> .44.3: 12 of 16 buckets identical, ~2.9 MB re-pulled).
#
# Two reasons for the bucketing rather than one asset layer or one-layer-per-pack:
# a single COPY re-pulls all 24 MB because each release adds a tiny version-named
# manifest dir that poisons the whole layer's hash; one layer per pack would be
# ~150 layers, past overlay2's ~127 cap. Bucketing is bounded AND adaptive — new
# packs and new version dirs need no Dockerfile edit. Without the mtime normalise
# the dedupe collapses: unzip stamps each release's build time onto every file,
# so an unchanged subtree still hashes to a fresh layer (measured: the frozen
# 13.2 MB resource_packs/vanilla went from a new digest per version to a shared
# one once normalised).
#
# A rollback is therefore just `docker pull <old tag>`: its asset buckets are
# already local, only its binary layer differs.
#
# Baking redistributes BDS, which the Minecraft EULA forbids (PLAN 7.3) —
# accepted here deliberately for the value it buys (small bumps, rollback, a
# self-contained runtime). The pin stays cryptographic: the fetch stage verifies
# BEDROCK_SHA256 before baking, so the baked layer cannot be a version other than
# the one on the tag; the build fails closed instead.
ARG BASE=chandlery/base:test
ARG MC_MONITOR=itzg/mc-monitor:latest
# curl/unzip/ca-certificates live only in the fetch stage; the runtime image
# ships none of them, and needs no network on first start.
ARG FETCH_BASE=debian:bookworm-slim

FROM ${MC_MONITOR} AS mc-monitor

# ---- fetch: download, verify, strip, split, normalise. Nothing here ships. ----
FROM ${FETCH_BASE} AS fetch

# No default: building "some version of Bedrock" is exactly what this project
# exists to stop. CI passes what Mojang currently ships, with the sha256 the CDN
# served for it.
ARG BEDROCK_VERSION
# The sha256 of the versioned zip. Optional to build, but CI always passes it:
# it is what turns "whatever that URL served at build" into a verified pin.
ARG BEDROCK_SHA256=
# Override to fetch from a mirror or cache instead of Mojang's CDN.
ARG BEDROCK_URL=
# The fixed mtime every baked file gets. A stable epoch is what makes an
# unchanged asset tree hash to the same layer across versions (SOURCE_DATE_EPOCH
# is the reproducible-build convention; 0 = 1970-01-01, and BDS does not care).
ARG SOURCE_DATE_EPOCH=0
# The number of asset-bucket layers. Kept in lockstep with the COPY lines in the
# runtime stage below — change both together.
ARG ASSET_BUCKETS=32

COPY --chmod=0755 bucketize /usr/local/bin/bucketize

RUN set -eux; \
    test -n "${BEDROCK_VERSION}" || { echo "BEDROCK_VERSION build-arg is required" >&2; exit 64; }; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl unzip; \
    rm -rf /var/lib/apt/lists/*; \
    url="${BEDROCK_URL:-https://www.minecraft.net/bedrockdedicatedserver/bin-linux/bedrock-server-${BEDROCK_VERSION}.zip}"; \
# The User-Agent matters, and not obviously: Mojang's Azure CDN kills the HTTP/2
# stream ("stream not closed cleanly: INTERNAL_ERROR") for a UA carrying spaces
# or parentheses — curl's default included. A plain token UA gets a clean 200.
# (itzg/docker-minecraft-bedrock-server#458.) Retries cover the CDN's real 503s.
    echo "downloading Bedrock ${BEDROCK_VERSION} from ${url}" >&2; \
    curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors --retry-max-time 300 \
         -A chandlery/bedrock -o /tmp/bds.zip "$url"; \
    if [ -n "${BEDROCK_SHA256}" ]; then \
        echo "verifying sha256" >&2; \
        echo "${BEDROCK_SHA256}  /tmp/bds.zip" | sha256sum -c -; \
    else \
        echo "WARNING: no BEDROCK_SHA256 pinned; baking whatever the URL served" >&2; \
    fi; \
    mkdir -p /stage /bin-layer; \
    unzip -q /tmp/bds.zip -d /stage; \
    rm -f /tmp/bds.zip; \
# Build-time leftovers that cannot run a game: the static link library, and the
# ~311 MB debug-symbols file older releases shipped.
    rm -f /stage/libMinecraft.Server.Lib.a /stage/bedrock_server_debug_symbols.debug; \
    test -x /stage/bedrock_server || { echo "no bedrock_server in the zip" >&2; exit 65; }; \
# Split the volatile binary out of the stable asset tree so it lands in its own
# COPY layer below.
    mv /stage/bedrock_server /bin-layer/bedrock_server; \
# Distribute the asset tree into ASSET_BUCKETS bucket dirs by subtree hash, so an
# unchanged subtree bakes into the same (dedupe-able) bucket layer every release.
    bucketize /stage /buckets "${ASSET_BUCKETS}"; \
    rm -rf /stage; \
# Normalise every mtime — files AND dirs — so an unchanged bucket bakes to a
# byte-identical layer across versions.
    find /buckets /bin-layer -exec touch --no-dereference -h -d "@${SOURCE_DATE_EPOCH}" {} +

# ---- runtime: base + monitor + two baked layers + adapter ----
FROM ${BASE}

ARG BEDROCK_VERSION

USER root

COPY --from=mc-monitor /mc-monitor /usr/local/bin/mc-monitor
# Asset buckets first: the lower, stable layers. Each is its own COPY so an
# unchanged bucket keeps its digest and is not re-pulled on a version bump. The
# count here MUST match ASSET_BUCKETS in the fetch stage.
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
COPY --chmod=0755 prepare   /usr/local/lib/chandlery/prepare
COPY --chmod=0755 stop-hook /usr/local/lib/chandlery/stop
COPY --chmod=0755 health    /usr/local/lib/chandlery/health
COPY --chmod=0755 run       /usr/local/bin/bedrock-server
# Binary last: the top layer, and the whole per-release delta. It changes every
# release while everything below it does not.
COPY --from=fetch --chown=chandlery:chandlery /bin-layer/bedrock_server /opt/bedrock/bedrock_server

# The version travels as environment so both halves see it — prepare (seed/link)
# and run (locate/exec) — and `docker inspect` shows what the image baked.
ENV BEDROCK_VERSION=${BEDROCK_VERSION}

USER chandlery
WORKDIR /data

# BDS is x86-64 only; there is no ARM build to fall back to.
LABEL org.opencontainers.image.title="Minecraft Bedrock Dedicated Server" \
      org.opencontainers.image.version="${BEDROCK_VERSION}" \
      org.opencontainers.image.source="https://github.com/danielbodart/chandlery" \
      org.opencontainers.image.licenses="Apache-2.0"

# 19132/udp is the game; 19133/udp is the IPv6 socket BDS insists on binding.
EXPOSE 19132/udp 19133/udp

# A protocol probe, not a port check: it proves the server answers players.
# start-period covers world generation; no first-run fetch to wait on any more.
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD ["/usr/local/lib/chandlery/health"]

CMD ["/usr/local/bin/bedrock-server"]
