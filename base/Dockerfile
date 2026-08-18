# The Chandlery skeleton: everything three game images agree on.
#
# Deliberately not much. tini for PID 1, an entrypoint that knows how to stop a
# server without losing the world, a non-root user, and /data. The game itself
# is baked in by the per-game image on top of this.
#
# glibc, not musl: Bedrock's binary and SteamCMD both want it.
ARG DEBIAN_TAG=bookworm-slim
FROM debian:${DEBIAN_TAG}

ARG CHANDLERY_UID=1000
ARG CHANDLERY_GID=1000
ARG CHANDLERY_USER=chandlery

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        tini \
        ca-certificates; \
    rm -rf /var/lib/apt/lists/*; \
    groupadd --gid "${CHANDLERY_GID}" "${CHANDLERY_USER}"; \
    useradd --uid "${CHANDLERY_UID}" --gid "${CHANDLERY_GID}" \
            --home-dir /data --no-create-home --shell /usr/sbin/nologin \
            "${CHANDLERY_USER}"; \
# /run/chandlery is created at build because the server user cannot mkdir in /run.
    mkdir -p /data /cache /run/chandlery /usr/local/lib/chandlery; \
    chown "${CHANDLERY_UID}:${CHANDLERY_GID}" /data /cache /run/chandlery

COPY --chmod=0755 entrypoint.sh /usr/local/bin/chandlery-entrypoint
COPY --chmod=0755 console.sh    /usr/local/bin/chandlery-console
COPY --chmod=0755 cache.sh      /usr/local/bin/chandlery-cache

ENV CHANDLERY_USER=${CHANDLERY_USER}

# /data is the world and config — the stuff worth backing up.
# /cache is the game payload, fetched and verified on first start (see PLAN 7.3).
# Keeping them apart means a backup of /data is not 350MB of game binaries, and
# a container recreate does not re-download.
VOLUME ["/data", "/cache"]
WORKDIR /data
USER ${CHANDLERY_USER}

# No HEALTHCHECK. A port-bound check is what any deployer already does, and it
# would do it better than we can from inside. Game images add one only when the
# game offers a probe that proves it is actually answering players.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/chandlery-entrypoint"]
