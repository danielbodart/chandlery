ARG BASE=chandlery/bedrock:test
FROM golang:1.27.3-alpine@sha256:d200d2dd76b03a99b52651fd1325aff7dcd35422c35c01bac56571b0507f3deb AS build
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -trimpath -o /raknet-pong main.go

FROM ${BASE}
USER root
COPY --from=build /raknet-pong /usr/local/bin/raknet-pong
USER chandlery
