ARG BASE=chandlery/base:test
FROM ${BASE}
USER root
COPY --chmod=0755 signal-server /usr/local/bin/signal-server
USER chandlery
CMD ["/usr/local/bin/signal-server"]
