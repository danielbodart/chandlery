# syntax=docker/dockerfile:1
#
# Hytale Dedicated Server — pinned, not baked.
#
# Like Bedrock and Valheim, the image carries no game content: every Hytale
# download is gated behind per-account OAuth and a signed, per-request URL
# (PLAN 7.1), so a public image cannot ship the bytes. It records the version
# and patchline, and on first start the operator's own downloader token fetches
# their entitled copy onto /cache through the shared chandlery-cache helper.
#
# Two auth flows, and the image holds neither credential:
#   - Fetching the assets needs a *downloader* access token — mint it on the host
#     with tools/hytale-token and pass HYTALE_ACCESS_TOKEN; needed only on the
#     first start of a version, since /cache keeps the rest.
#   - Running the server is token passthrough: the deployer injects
#     HYTALE_SERVER_SESSION_TOKEN and HYTALE_SERVER_IDENTITY_TOKEN, exactly the
#     way Valheim takes its password. HYTALE_AUTH_MODE=offline needs neither and
#     is for LAN and our own tests.
ARG BASE=chandlery/base:test
# Pinned, like everything else here: a floating 25-jre would drift the JRE under
# a tag that is supposed to mean one exact thing. Bump this deliberately (it is
# an ARG) rather than letting a rebuild pick up a new one. Temurin is Adoptium's
# OpenJDK; the game needs Java 25.
ARG JAVA=eclipse-temurin:25.0.3_9-jre

FROM ${JAVA} AS java

FROM ${BASE}

ARG HYTALE_VERSION
ARG HYTALE_PATCHLINE=release
# Optional, but CI passes it: the sha256 of the build zip, which turns the
# first-boot download into a cryptographic pin (like Bedrock). Absent, the fetch
# still verifies against the manifest's own sha256.
ARG HYTALE_SHA256=

USER root
RUN set -eux; \
    test -n "${HYTALE_VERSION}" || { echo "HYTALE_VERSION build-arg is required" >&2; exit 64; }; \
    apt-get update; \
# jq parses the version manifest and the signed-URL responses at fetch time.
    apt-get install -y --no-install-recommends ca-certificates curl unzip jq; \
    rm -rf /var/lib/apt/lists/*

# Java 25, from Temurin. The server needs a JRE; the game jar is fetched at start.
COPY --from=java /opt/java/openjdk /opt/java/openjdk
ENV JAVA_HOME=/opt/java/openjdk \
    PATH=/opt/java/openjdk/bin:/usr/local/bin:/usr/bin:/bin

COPY --chmod=0755 fetch     /usr/local/lib/chandlery/fetch
COPY --chmod=0755 prepare   /usr/local/lib/chandlery/prepare
COPY --chmod=0755 stop-hook /usr/local/lib/chandlery/stop
COPY --chmod=0755 run       /usr/local/bin/hytale-server

# The pin travels as environment; prepare fetches it, run locates it.
ENV HYTALE_VERSION=${HYTALE_VERSION} \
    HYTALE_PATCHLINE=${HYTALE_PATCHLINE} \
    HYTALE_SHA256=${HYTALE_SHA256}

# We control the version through the tag. The server ships an hourly auto-updater
# that would rewrite its own binaries out from under that (PLAN 7.1), so it stays
# off — CI and the deployer do that job for the other two games too.
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
