ARG BASE=chandlery/base:test
FROM ${BASE}
USER root
COPY --chmod=0755 fake-server /usr/local/bin/fake-server
COPY --chmod=0755 stop-hook    /usr/local/lib/chandlery/stop
COPY --chmod=0755 prepare-hook /usr/local/lib/chandlery/prepare
USER chandlery
CMD ["/usr/local/bin/fake-server"]
