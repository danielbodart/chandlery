# The Valheim image's adapter — its prepare checks, the fetch cache fast path,
# argument assembly, stop hook and health probe — on top of a fake server, so
# all of it is testable without SteamCMD and a 1.6 GB download.
#
# The fake stands in for a build already fetched to /cache: it is laid down at a
# fake manifest gid with the readiness marker chandlery-cache looks for, so
# prepare takes its already-cached path and never reaches SteamCMD (which this
# image does not carry). Build from the repository root: this deliberately
# copies the real scripts, so a change to the adapter changes what is tested.
ARG BASE=chandlery/base:test

FROM golang:1.24-alpine AS build
WORKDIR /src
COPY test/fixtures/fake-valheim/go.mod test/fixtures/fake-valheim/main.go ./
RUN CGO_ENABLED=0 go build -trimpath -o /fake-valheim .

FROM golang:1.24-alpine AS probe
WORKDIR /src
COPY valheim/probe/go.mod valheim/probe/main.go ./
RUN CGO_ENABLED=0 go build -trimpath -o /chandlery-a2s .

FROM ${BASE}
USER root

# A fake build, already "fetched" into the cache the real fetch would populate.
ARG VALHEIM_MANIFEST_GID=0000000000000000000
COPY --from=build --chown=chandlery:chandlery \
     /fake-valheim /cache/valheim/${VALHEIM_MANIFEST_GID}/valheim_server.x86_64
RUN : > /cache/valheim/${VALHEIM_MANIFEST_GID}/.chandlery-ready \
 && chown -R chandlery:chandlery /cache/valheim

COPY --from=probe /chandlery-a2s /usr/local/bin/chandlery-a2s
COPY --chmod=0755 valheim/run       /usr/local/bin/valheim-server
COPY --chmod=0755 valheim/prepare   /usr/local/lib/chandlery/prepare
COPY --chmod=0755 valheim/stop-hook /usr/local/lib/chandlery/stop
COPY --chmod=0755 valheim/health    /usr/local/lib/chandlery/health

# The pin the adapter reads. No real SteamCMD download stands behind this gid;
# the readiness marker above is what makes prepare skip the fetch.
ENV VALHEIM_MANIFEST_GID=${VALHEIM_MANIFEST_GID} \
    VALHEIM_BUILD_ID=fake \
    VALHEIM_APP_ID=896660 \
    VALHEIM_DEPOT_ID=896661

USER chandlery
WORKDIR /data
CMD ["/usr/local/bin/valheim-server"]
