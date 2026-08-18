# The Hytale image's adapter — its prepare checks, the fetch cache fast path,
# argument assembly and stop hook — on top of a fake server, so all of it is
# testable without a downloader token or the 3.3 GB asset download.
#
# The fake stands in for a version already fetched to /cache: a stub jar and
# assets dir at a fake version, with the readiness marker chandlery-cache looks
# for, so prepare takes its already-cached path and never reaches the fetch. A
# fake `java` on PATH is what the real run script execs. Build from the
# repository root, so the real adapter scripts are what these tests exercise.
ARG BASE=chandlery/base:test

FROM ${BASE}
USER root

ARG HYTALE_VERSION=0.0.0-fake
# Mirror the real extracted layout: Server/HytaleServer.jar and Assets.zip next
# to it, which is what hytale/run locates and points --assets at.
RUN mkdir -p "/cache/hytale/${HYTALE_VERSION}/Server" \
 && : > "/cache/hytale/${HYTALE_VERSION}/Server/HytaleServer.jar" \
 && : > "/cache/hytale/${HYTALE_VERSION}/Assets.zip" \
 && : > "/cache/hytale/${HYTALE_VERSION}/.chandlery-ready" \
 && chown -R chandlery:chandlery /cache/hytale

# A fake `java`, ahead of nothing (the base ships no JRE), that the real run
# script execs. Kept on PATH under /usr/local/bin.
COPY --chmod=0755 test/fixtures/fake-hytale/java /usr/local/bin/java

COPY --chmod=0755 hytale/run       /usr/local/bin/hytale-server
COPY --chmod=0755 hytale/prepare   /usr/local/lib/chandlery/prepare
COPY --chmod=0755 hytale/stop-hook /usr/local/lib/chandlery/stop

ENV HYTALE_VERSION=${HYTALE_VERSION} \
    HYTALE_PATCHLINE=release \
    HYTALE_DISABLE_UPDATES=1

USER chandlery
WORKDIR /data
CMD ["/usr/local/bin/hytale-server"]
