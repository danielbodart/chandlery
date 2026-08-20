# The Valheim image's adapter — its prepare checks, argument assembly, stop hook
# and health probe — on top of a fake server, so all of it is testable without a
# Steam token and the 1.6 GB download.
#
# The image is baked (PLAN 7.3), so the fake stands in for the baked game: a fake
# server and a stub steamclient.so at /opt/valheim, exactly where the real build
# puts them and where run/prepare look. Build from the repository root: this
# deliberately copies the real scripts, so a change to the adapter changes what
# is tested.
ARG BASE=chandlery/base:test

FROM golang:1.24-alpine AS build
WORKDIR /src
COPY test/fixtures/fake-valheim/go.mod test/fixtures/fake-valheim/main.go ./
RUN CGO_ENABLED=0 go build -trimpath -o /fake-valheim .

FROM golang:1.24-alpine AS probe
WORKDIR /src
COPY images/valheim/probe/go.mod images/valheim/probe/main.go ./
RUN CGO_ENABLED=0 go build -trimpath -o /chandlery-a2s .

FROM ${BASE}
USER root

# A fake baked game where the real build lays it down. A stub steamclient.so so
# run's Steam-library wiring has something to point at.
COPY --from=build --chown=chandlery:chandlery /fake-valheim /opt/valheim/valheim_server.x86_64
RUN : > /opt/valheim/steamclient.so && chown -R chandlery:chandlery /opt/valheim

COPY --from=probe /chandlery-a2s /usr/local/bin/chandlery-a2s
COPY --chmod=0755 images/valheim/run       /usr/local/bin/valheim-server
COPY --chmod=0755 images/valheim/prepare   /usr/local/lib/chandlery/prepare
COPY --chmod=0755 images/valheim/stop-hook /usr/local/lib/chandlery/stop
COPY --chmod=0755 images/valheim/health    /usr/local/lib/chandlery/health

# The pin the adapter reads. No real bytes stand behind this gid; the baked fake
# above is what run locates.
ENV VALHEIM_MANIFEST_GID=0000000000000000000 \
    VALHEIM_BUILD_ID=fake \
    VALHEIM_APP_ID=896660 \
    VALHEIM_DEPOT_ID=896661

USER chandlery
WORKDIR /data
# Mirror the real image's CMD so the tests exercise the default-args path; a test
# that passes its own arguments after the image overrides these, as compose
# `command:` would.
CMD ["/usr/local/bin/valheim-server", "-name", "Chandlery", "-world", "Dedicated", "-port", "2456", "-public", "1"]
