# The Hytale image's adapter — its prepare checks, argument assembly and stop
# hook — on top of a fake server, so all of it is testable without a downloader
# token or the 3.3 GB asset download.
#
# The image is baked (PLAN 7.3), so the fake stands in for the baked game: a stub
# jar and Assets.zip at /opt/hytale, exactly where the real build puts them and
# where run locates them. A fake `java` on PATH is what the real run script
# execs. Build from the repository root, so the real adapter scripts are tested.
ARG BASE=chandlery/base:test

FROM ${BASE}
USER root

# Mirror the real image: curl is present for run's boot-time Treesinger fetch.
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl \
 && rm -rf /var/lib/apt/lists/*

ARG HYTALE_VERSION=0.0.0-fake
# Mirror the real baked layout: Server/HytaleServer.jar and Assets.zip next to
# it, which is what images/hytale/run locates and points --assets at.
RUN mkdir -p /opt/hytale/Server \
 && : > /opt/hytale/Server/HytaleServer.jar \
 && : > /opt/hytale/Assets.zip \
 && chown -R chandlery:chandlery /opt/hytale

# A fake `java`, ahead of nothing (the base ships no JRE), that the real run
# script execs. Kept on PATH under /usr/local/bin.
COPY --chmod=0755 test/fixtures/fake-hytale/java /usr/local/bin/java

COPY --chmod=0755 images/hytale/run       /usr/local/bin/hytale-server
COPY --chmod=0755 images/hytale/prepare   /usr/local/lib/chandlery/prepare
COPY --chmod=0755 images/hytale/stop-hook /usr/local/lib/chandlery/stop

ENV HYTALE_VERSION=${HYTALE_VERSION} \
    HYTALE_PATCHLINE=release \
    HYTALE_DISABLE_UPDATES=1

USER chandlery
WORKDIR /data
CMD ["/usr/local/bin/hytale-server"]
