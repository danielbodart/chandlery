# Valheim — Chandlery image

Valheim dedicated server, where the **image tag is the game version**, baked in —
nothing downloads at container start.

## Run

Valheim requires a password (≥5 characters, and not contained in the world name —
Valheim's own rules, enforced by the server). Keep it in a `.env`, never in
`command:`.

```yaml
services:
  valheim:
    image: ghcr.io/danielbodart/chandlery/valheim:latest
    environment:
      VALHEIM_PASSWORD: ${VALHEIM_PASSWORD:?set it in .env}
    ports: ["2456:2456/udp", "2457:2457/udp"]
    volumes: ["valheim-data:/data"]
    stop_grace_period: 5m
```

## Configuration

Valheim has **no config file** — its whole configuration is command-line flags.

- **`VALHEIM_PASSWORD`** (environment) — the one required value, and the *only*
  environment variable this image reads. It's a secret, so it lives in the
  environment, not in a plaintext `command:`. No validation is done here:
  Valheim's rules (length, absent from the world name) are the server's own, and
  it reports them itself — we don't keep a second, drifting copy.

- **`-name` / `-world` / `-port` / `-public`** — defaulted in the image
  (`Chandlery` / `Dedicated` / `2456` / `1`). Override them, or add any other
  server flag, natively through compose `command:` (an argv array — no
  word-splitting):

  ```yaml
  command: ["valheim-server", "-name", "Harbour", "-world", "Longship", "-crossplay"]
  ```

  `command:` replaces the whole default set, so restate the flags you still want.
  The adapter always adds `-nographics -batchmode -savedir /data` and the
  password — those are not yours to pass.

## Ports, stop, health

- **2456/udp** game, **2457/udp** Steam query (the game port + 1; Valheim ties the
  two together). To move them, remap **host-side**. Changing the *internal* port
  means `command: ["valheim-server", "-port", "N", …]` — rare — after which you
  should override the `healthcheck:` in compose to probe `N+1`.
- **Stops** on `SIGINT`, the signal Valheim saves on. Give it time:
  `stop_grace_period: 5m`.
- **Health**: a Steam `A2S_INFO` query, which proves the server is answering.

> GHCR shows the repository's root README on every package page, not this file —
> it has no per-image README. This is the canonical per-image documentation.
