# The Valheim image's adapter — its prepare checks, argument assembly, stop
# hook and health probe — on top of a fake server, so all of it is testable
# without SteamCMD and a 1 GB download.
#
# Build from the repository root: this deliberately copies the real scripts
# rather than a copy of them, so a change to the adapter is a change to what
# these tests exercise.
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
COPY --from=build /fake-valheim /opt/valheim/valheim_server.x86_64
COPY --from=probe /chandlery-a2s /usr/local/bin/chandlery-a2s
COPY --chmod=0755 valheim/run       /usr/local/bin/valheim-server
COPY --chmod=0755 valheim/prepare   /usr/local/lib/chandlery/prepare
COPY --chmod=0755 valheim/stop-hook /usr/local/lib/chandlery/stop
COPY --chmod=0755 valheim/health    /usr/local/lib/chandlery/health
USER chandlery
WORKDIR /opt/valheim
CMD ["/usr/local/bin/valheim-server"]
