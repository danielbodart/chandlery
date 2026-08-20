# Bedrock — Chandlery image

Minecraft Bedrock Dedicated Server, where the **image tag is the game version**:
`ghcr.io/danielbodart/chandlery/bedrock:1.26.44.3` is exactly that BDS, verified
and baked in — nothing downloads at container start.

## Run

```console
docker run -d --name bedrock -p 19132:19132/udp -v bedrock-data:/data \
  --stop-timeout 300 ghcr.io/danielbodart/chandlery/bedrock:latest
```

## Configuration

All of it lives in **`/data/server.properties`** — BDS's own file, the single
source of truth. Edit it on the volume. There are **no configuration environment
variables**. `allowlist.json` and `permissions.json` live on `/data` too, seeded
from the baked version on first start.

## Extra arguments

BDS reads the properties file, not flags, so you should almost never need to pass
any. Anything you do put in compose `command:` is forwarded to the server
verbatim:

```yaml
command: ["bedrock-server", "--help"]
```

## Ports, stop, health

- **19132/udp** game (19133/udp is the IPv6 socket BDS insists on binding). To
  move it, remap **host-side** (`-p 19200:19132/udp`) — the container-internal
  port stays 19132. To change the internal port, set `server-port=` in
  `server.properties`; the health probe reads it from there.
- **Stops** via `stop` on the console, which saves the world before exit. Give it
  time: `--stop-timeout 300` / `stop_grace_period: 5m`.
- **Health**: a RakNet unconnected-ping (mc-monitor) that proves the server is
  answering players, not merely holding the port.

Talk to a running server: `docker exec bedrock chandlery-console say hello`.

> GHCR shows the repository's root README on every package page, not this file —
> it has no per-image README. This is the canonical per-image documentation.
