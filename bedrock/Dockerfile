# syntax=docker/dockerfile:1
#
# Minecraft Bedrock Dedicated Server, baked in at build time.
#
# The tag is the version: chandlery/bedrock:1.26.44.3 contains exactly BDS
# 1.26.44.3 and always will. Nothing is downloaded when the container starts.
ARG BASE=chandlery/base:test
ARG MC_MONITOR=itzg/mc-monitor:latest

FROM ${MC_MONITOR} AS mc-monitor

FROM debian:bookworm-slim AS fetch

# No default: building "some version of Bedrock" is exactly what this project
# exists to stop. Callers pass one, and CI passes what Mojang currently ships.
ARG BEDROCK_VERSION
# Optional, but pass it in CI: it turns "whatever that URL served" into a
# verified artefact.
ARG BEDROCK_SHA256=
# Override to build from a mirror or a cached copy instead of Mojang's CDN.
ARG BEDROCK_URL=

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl unzip; \
    rm -rf /var/lib/apt/lists/*

# Networks that re-terminate TLS (corporate egress proxies, and the sandbox this
# was developed in) present a CA the base image does not know. Optional: pass
# --secret id=extra-ca,src=/path/to/ca.crt to trust one. Absent, this is a no-op.
RUN --mount=type=secret,id=extra-ca \
    if [ -s /run/secrets/extra-ca ]; then \
        cp /run/secrets/extra-ca /usr/local/share/ca-certificates/extra-ca.crt; \
        update-ca-certificates; \
    fi

RUN set -eux; \
    test -n "${BEDROCK_VERSION}" || { echo "BEDROCK_VERSION build-arg is required" >&2; exit 64; }; \
    url="${BEDROCK_URL:-https://www.minecraft.net/bedrockdedicatedserver/bin-linux/bedrock-server-${BEDROCK_VERSION}.zip}"; \
# Mojang's CDN rate-limits and answers 503 under load; a version bump that
# fails on a transient blip would look exactly like a broken release.
    curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors --retry-max-time 300 \
         -A "chandlery (+https://github.com/danielbodart/chandlery)" -o /tmp/bds.zip "$url"; \
    if [ -n "${BEDROCK_SHA256}" ]; then echo "${BEDROCK_SHA256}  /tmp/bds.zip" | sha256sum -c -; fi; \
    mkdir -p /stage/game /stage/bin; \
    unzip -q /tmp/bds.zip -d /stage/game; \
    rm /tmp/bds.zip; \
# Build-time leftovers. The static library is for linking against the server,
# and older releases shipped a ~311 MB debug-symbols file; neither runs a game.
    rm -f /stage/game/libMinecraft.Server.Lib.a \
          /stage/game/bedrock_server_debug_symbols.debug; \
# The four paths BDS treats as state live on /data. It has no config-path flag,
# so the links go the other way: the game dir points out at the volume.
    mkdir -p /stage/game/.defaults; \
    mv /stage/game/server.properties \
       /stage/game/allowlist.json \
       /stage/game/permissions.json /stage/game/.defaults/; \
    ln -s /data/server.properties /stage/game/server.properties; \
    ln -s /data/allowlist.json    /stage/game/allowlist.json; \
    ln -s /data/permissions.json  /stage/game/permissions.json; \
    ln -s /data/worlds            /stage/game/worlds; \
# Split the volatile 230 MB binary off the assets, so a version bump re-pulls
# the binary layer and reuses the packs when they have not changed.
    mv /stage/game/bedrock_server /stage/bin/bedrock_server

FROM ${BASE}

ARG BEDROCK_VERSION
USER root

COPY --from=mc-monitor /mc-monitor /usr/local/bin/mc-monitor
COPY --from=fetch --chown=chandlery:chandlery /stage/game/ /opt/bedrock/
COPY --from=fetch --chown=chandlery:chandlery /stage/bin/bedrock_server /opt/bedrock/bedrock_server
COPY --chmod=0755 prepare   /usr/local/lib/chandlery/prepare
COPY --chmod=0755 stop-hook /usr/local/lib/chandlery/stop
COPY --chmod=0755 health    /usr/local/lib/chandlery/health

USER chandlery
WORKDIR /opt/bedrock

# BDS is x86-64 only; there is no ARM build to fall back to.
LABEL org.opencontainers.image.title="Minecraft Bedrock Dedicated Server" \
      org.opencontainers.image.version="${BEDROCK_VERSION}" \
      org.opencontainers.image.source="https://github.com/danielbodart/chandlery" \
      org.opencontainers.image.licenses="Apache-2.0"

# 19132/udp is the game; 19133/udp is the IPv6 socket BDS insists on binding.
EXPOSE 19132/udp 19133/udp

# A protocol probe, not a port check: it proves the server answers players.
# start-period covers first-run world generation.
HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
    CMD ["/usr/local/lib/chandlery/health"]

CMD ["./bedrock_server"]
