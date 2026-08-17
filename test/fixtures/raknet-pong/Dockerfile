ARG BASE=chandlery/bedrock:test
FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -trimpath -o /raknet-pong main.go

FROM ${BASE}
USER root
COPY --from=build /raknet-pong /usr/local/bin/raknet-pong
USER chandlery
