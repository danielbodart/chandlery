# Hytale — Chandlery image

Hytale dedicated server, where the **image tag is the game version**, baked in —
nothing downloads at container start.

## Run

```yaml
services:
  hytale:
    image: ghcr.io/danielbodart/chandlery/hytale:latest
    ports: ["5520:5520/udp"]
    volumes: ["hytale-data:/data"]
    stop_grace_period: 5m
```

## Configuration

Config lives in **`/data/config.json`** — the server's own file (name, world,
players, mods). Worlds, players, logs and backups all live on `/data` too.

### Authentication

The server boots **online** by default and runs unauthenticated (fine for LAN and
direct-connect) until you log it in. Authenticate once on the console; it persists
to `/data/auth.enc`:

```console
docker exec hytale chandlery-console /auth login
docker logs hytale        # read the device code + URL, then authorize
```

Alternatively, inject the server's **own** environment variables,
`HYTALE_SERVER_SESSION_TOKEN` and `HYTALE_SERVER_IDENTITY_TOKEN` — these are
Hytale's variables, read by the server itself (never placed on the command line).

## Extra arguments

Any server flag passes straight through via compose `command:` — no environment
re-encoding. `command:` replaces the default command, so it names the wrapper
first:

```yaml
command: ["hytale-server", "--auth-mode", "offline", "--max-players", "40"]
```

The adapter always sets `-jar … --assets … --disable-sentry --backup …`; your
arguments append after those. Custom JVM options go in `/data/jvm.options`, one
flag per line.

## Ports, stop, health

- **5520/udp** (QUIC). To move it, remap **host-side**; the container-internal
  port stays 5520.
- **Stops** via `/stop` on the console, which saves the world, players and config
  before exit. Give it time: `stop_grace_period: 5m`.
- **Health**: none. Hytale ships no in-box protocol probe, and a port-bound check
  is what a deployer already does, better.

> GHCR shows the repository's root README on every package page, not this file —
> it has no per-image README. This is the canonical per-image documentation.
