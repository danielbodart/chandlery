ARG BASE=chandlery/base:test
FROM ${BASE}
USER root
COPY --chmod=0755 fake-server /usr/local/bin/fake-server
COPY --chmod=0755 stop-hook   /usr/local/lib/chandlery/stop
USER chandlery
CMD ["/usr/local/bin/fake-server"]
