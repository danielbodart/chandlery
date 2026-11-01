# A RakNet unconnected-pong responder on top of the Bedrock image, so the
# health check (mc-monitor) has something to ping without a real BDS. Build
# from the repository root: the binary is `mise run fixtures`' output.
ARG BASE=chandlery/bedrock:test
FROM ${BASE}
USER root
COPY --chmod=0755 test/fixtures/bin/linux-amd64/raknet-pong /usr/local/bin/raknet-pong
USER chandlery
