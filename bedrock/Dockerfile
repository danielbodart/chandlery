# syntax=docker/dockerfile:1
#
# Minecraft Bedrock Dedicated Server — pinned, not baked.
#
# The image carries no game content: Mojang's EULA forbids giving copies of the
# server to anyone else, and a public image would do exactly that (PLAN 7.3). It
# records instead precisely *which* version — the versioned download URL and its
# sha256 — precisely enough that it cannot run anything else, and fetches the
# bytes from Mojang on first start, checking them against that sha256 before it
# will run them. The tag is still the version; the pin is now cryptographic, and
# chandlery/bedrock:1.26.44.3 can never run anything but 1.26.44.3.
ARG BASE=chandlery/base:test
ARG MC_MONITOR=itzg/mc-monitor:latest

FROM ${MC_MONITOR} AS mc-monitor

FROM ${BASE}

# No default: building "some version of Bedrock" is exactly what this project
# exists to stop. CI passes what Mojang currently ships, with the sha256 the CDN
# served for it.
ARG BEDROCK_VERSION
# The sha256 of the versioned zip. Optional to build, but CI always passes it:
# it is what turns "whatever that URL serves on first boot" into a verified pin.
ARG BEDROCK_SHA256=
# Override to fetch from a mirror or cache instead of Mojang's CDN.
ARG BEDROCK_URL=

USER root
RUN set -eux; \
    test -n "${BEDROCK_VERSION}" || { echo "BEDROCK_VERSION build-arg is required" >&2; exit 64; }; \
# Runtime fetch needs these; the base stays game-agnostic and ships neither.
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl unzip; \
    rm -rf /var/lib/apt/lists/*

COPY --from=mc-monitor /mc-monitor /usr/local/bin/mc-monitor
COPY --chmod=0755 fetch     /usr/local/lib/chandlery/fetch
COPY --chmod=0755 prepare   /usr/local/lib/chandlery/prepare
COPY --chmod=0755 stop-hook /usr/local/lib/chandlery/stop
COPY --chmod=0755 health    /usr/local/lib/chandlery/health
COPY --chmod=0755 run       /usr/local/bin/bedrock-server

# The pin travels as environment so both halves see it — prepare (fetch/verify)
# and run (locate/exec) — and `docker inspect` shows what a first start will pull.
ENV BEDROCK_VERSION=${BEDROCK_VERSION} \
    BEDROCK_SHA256=${BEDROCK_SHA256} \
    BEDROCK_URL=${BEDROCK_URL}

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
# start-period covers the first-run fetch as well as world generation.
HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
    CMD ["/usr/local/lib/chandlery/health"]

CMD ["/usr/local/bin/bedrock-server"]
