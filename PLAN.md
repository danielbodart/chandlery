# Chandlery — design & build plan

> A *chandlery* is the harbour-side shop that provisions ships for their voyage. This one provisions your servers with their game — baked into an image, versioned, ready to sail.

Status: **planning**. This document is the brief for the build session. Nothing here is built yet.

---

## 1. What it is

A mono-repo of **clean-room, Docker-native game-server images**, where the **image tag *is* the game version**. Each game's server is installed **at image-build time** (not downloaded at container start), so:

- `chandlery/bedrock:1.26.44` is exactly Bedrock 1.26.44 — reproducible, pinned, rollback-able.
- A new game release triggers a **rebuild** of that image, tagged with the new version + `:latest`.
- The running lifecycle is plain Docker: `tini` as PID 1, a graceful stop that **saves before it exits**, a real health check, `restart` policy for crashes — no bespoke supervisor.

First three games: **Minecraft Bedrock**, **Valheim**, **Hytale**. Structured so more slot in via a small per-game adapter.

This is the **build** half of the fleet; its sibling [`tidewaiter`](https://github.com/danielbodart/tidewaiter) is the **deploy** half — it watches these images and swaps a running container for a newer one *when the server is idle*, health-gated, with rollback. Chandlery images therefore ship with Tidewaiter's labels so the loop closes end to end. (Both sit beside [`portical`](https://github.com/danielbodart/portical) in the harbour.)

---

## 2. Why build it (the gap)

We run LinuxGSM today and its Docker images never felt native: the game is downloaded *inside* the container at runtime, so the image tag says nothing about the game version; start/stop/monitor is a pile of pre-Docker shell; and this month a flaky LinuxGSM query-monitor bounced a live Bedrock server every ~3 minutes. The alternatives each give up something:

| Option | Native lifecycle | image = version | Covers our games |
| --- | --- | --- | --- |
| **LinuxGSM docker** | ✗ (runtime download, tmux, monitor cron) | ✗ | many, incl. Bedrock/Valheim |
| **itzg** (minecraft-server / -bedrock) | ✓✓ (mc-server-runner, mc-monitor) | ✗ (runtime download, version via env) | Minecraft only |
| **cm2network / community Steam** | ✓ | ~ (some CI-rebuild, tag=buildid) | Steam only |
| **Pterodactyl/Pelican** panels | panel-managed | ✗ (generic image + volume install) | many |

No one covers **Bedrock + Steam + Hytale** with **image = version + native lifecycle + rebuild-on-release**. The reason the field is fragmented is that these three games use **three different distribution mechanisms** — Mojang direct download, Steam/SteamCMD, Hytale OAuth — so each existing project specialises in one. Chandlery's answer is a **common skeleton + per-game source adapters**.

### Prior art to reference (house rule: look first, cite it)
- **[docker-gameserver](https://github.com/GameServerManagers/docker-gameserver)** (LinuxGSM's own) — its Jinja-templated per-game Dockerfiles from one base is the *structure* to emulate. We take the structure but **bake at build time, not download at runtime**.
- **[itzg/mc-server-runner](https://github.com/itzg/mc-server-runner)** — the gold-standard graceful stop: PID 1 that wires the console and turns SIGTERM into an in-band `stop`, then waits. Reference (or reuse) for the Minecraft stop hook.
- **[itzg/mc-monitor](https://github.com/itzg/mc-monitor)** — a reliable Minecraft status probe for the health check (the *right* answer to the LinuxGSM gamedig false-positive that caused the 3-minute restart loop).
- **[cm2network](https://hub.docker.com/u/cm2network)** — the SteamCMD base-image pattern for Steam games.
- **lloesche/valheim-server & community-valheim-tools** — Valheim specifics (world save/backup, the player-gated update they do by hand — now Tidewaiter's job).
- **[api.steamcmd.net](https://api.steamcmd.net/v1/info/896660)** — cheap way to poll a Steam app's `public` branch `buildid` in CI without running SteamCMD (fast-path; use real `steamcmd +app_info_print` as the canonical check). Valheim = app **896660**.
- **[Agones](https://agones.dev)** / **tidewaiter** — the deploy/activity-gated side of the loop these images plug into.

---

## 3. Architecture: common skeleton + source adapters

Mono-repo layout (structure to confirm in build):

```
chandlery/
  base/            # the shared skeleton image
    Dockerfile     #   tini as PID 1, entrypoint framework, non-root user, /data
    entrypoint.sh  #   runs the server; on SIGTERM runs the game's stop-hook, waits
    healthcheck.sh #   dispatches to the game's health probe
  bedrock/
    Dockerfile     #   FROM base; MOJANG download baked in; tag = version
    stop-hook      #   write "stop" to the server's stdin (FIFO)
    health         #   RakNet unconnected-ping (or port-bound)
  valheim/
    Dockerfile     #   FROM base; steamcmd +app_update 896660 baked in; tag = buildid
    stop-hook      #   forward SIGINT (Valheim saves on SIGINT/SIGTERM)
    health         #   Steam A2S query (or port-bound)
  hytale/
    Dockerfile     #   FROM base; Hytale download/OAuth baked in; tag = version
    stop-hook      #   TBD from the server's shutdown semantics
    health         #   port-bound (protocol probe TBD)
  .github/workflows/
    <game>.yml     #   per-game: poll source version, rebuild+push on change
```

### The base skeleton
- **`tini`** as PID 1 (zombie reaping, clean signal forwarding).
- **Entrypoint** execs the server, and on `SIGTERM` runs the game's **stop hook** (an in-band save+quit) and **waits** for a clean exit, bounded by `stop_grace_period`. This is the itzg/mc-server-runner idea, generalised behind a per-game hook.
- **Non-root user**, world/config on a **`/data`** volume (so a container recreate keeps the world; the game *binaries* live in the image).
- **Health check** dispatches to the game's probe; default to a generic **port-bound / TCP-connect** check when no protocol probe exists (mirrors Tidewaiter's health ladder).
- Carries default **Tidewaiter labels** (see §5).

### Per-game source adapter (build time)
Each game's Dockerfile does one job at build: **install the exact version and bake it in**.
- **Bedrock** — download Mojang's Bedrock dedicated-server zip for a given version, unzip into the image. Drop the debug-symbols file (≈311 MB) — huge and useless in prod. Result is *smaller* than the 1.17 GB LinuxGSM image.
- **Valheim** — `steamcmd +login anonymous +app_update 896660 +quit` at build; bake the result.
- **Hytale** — bake the downloaded server; auth is the open question (its download needs OAuth — see §7).

---

## 4. Rebuild-on-release (the "always current" bit)

Per game, a **scheduled CI workflow** (hourly-ish):
1. Resolve the **latest upstream version** — Bedrock: Mojang's version/download endpoint; Valheim: SteamCMD `public` buildid (api.steamcmd.net fast-path, `steamcmd` canonical); Hytale: its release/version source.
2. Compare to the **last built** (the newest image tag, or a recorded marker).
3. If changed: build the image with that version baked in, tag `:<version>` **and** `:latest`, push to Docker Hub + GHCR.

Then Tidewaiter (running on the host) sees the new `:latest` digest and, when the server is empty, pulls + swaps + health-checks + (on failure) rolls back. **Upstream releases → CI rebuilds image=version → Tidewaiter deploys when idle.** Hands-off.

---

## 5. Tidewaiter integration (labels the images ship with)

Each image sets sensible defaults so a deployer gets safe auto-update for free (overridable in compose):

| Label | Bedrock | Valheim | Hytale |
| --- | --- | --- | --- |
| `tidewaiter.autoupdate` | `registry` | `registry` | `registry` |
| `tidewaiter.detector` | `conntrack` (UDP) | `conntrack` (UDP) | `conntrack` |
| `tidewaiter.health` | `docker,port-bound` | `docker,port-bound` | `port-bound` |

(Bedrock/Valheim are UDP, so conntrack is the detector that can see players — see the tidewaiter plan.)

---

## 6. Graceful stop & health, per game

| Game | Stop (save before exit) | Health probe |
| --- | --- | --- |
| **Bedrock** | write `stop` to server stdin via a FIFO, wait for exit (BDS does not save cleanly on a bare SIGTERM) | RakNet unconnected-ping on the game port (returns MOTD); fallback port-bound |
| **Valheim** | forward `SIGINT`/`SIGTERM` (Valheim saves the world on signal) and wait | Steam A2S_INFO query; fallback port-bound |
| **Hytale** | TBD — determine the server's clean-shutdown command/signal | port-bound; protocol probe TBD |

Set a generous `stop_grace_period` in the shipped compose so a large world save finishes before Docker sends SIGKILL.

---

## 7. Open questions (resolve in build)
- **Hytale auth in CI.** Its server download needs OAuth. Can a build-time bake use a machine/service credential, or must Hytale stay runtime-download (breaking image=version for that one)? Investigate before committing Hytale to the baked model. Its rootfs is ~3.9 GB (measured), so also weigh image size.
- **Layering to keep updates small.** Split each Dockerfile so rarely-changing assets sit in a lower layer and the volatile binary in the top layer, so a version bump re-pulls only the small layer (helps MC a lot; Steam's `app_update` rewrites broadly, so gains are limited — measure).
- **Steam auth** — public dedicated servers install via `login anonymous`; confirm none of ours need a real account.
- **Base image choice** — alpine vs debian-slim per game (Bedrock's binary wants glibc → debian-slim; Steam games likewise). The base may need to be glibc, not musl.
- **Version marker** for CI "did it change" — newest pushed tag vs a state file.
- Do we generate per-game Dockerfiles from a template (docker-gameserver style) or hand-write three? Three is fine now; template if the count grows.

## 8. Build order (milestones)
1. **Base skeleton**: tini + entrypoint (stop-hook dispatch) + healthcheck dispatch + non-root + /data. A trivial "sleep server" proves stop/health wiring.
2. **Bedrock**: Mojang adapter (baked, drop symbols), stdin-`stop` hook, RakNet health. Replace the LinuxGSM Bedrock servers first (the ones we fought this month).
3. **Bedrock CI**: rebuild-on-Mojang-release, tag=version, push.
4. **Valheim**: SteamCMD adapter (896660), SIGINT stop, A2S health, CI on buildid.
5. **Hytale**: resolve auth (§7); if bake-able, adapter + CI; else document why it stays runtime-download.
6. **Ship + adopt**: publish images, wire Tidewaiter labels, migrate the homelab (`danielbodart/server`) off LinuxGSM one game at a time.

## 9. Non-goals (v1)
- No mod/plugin management surface (that's itzg's turf for Java — we're not doing Minecraft Java here; itzg stays for Java).
- No panel/UI.
- No multi-host orchestration.
- Chandlery builds & bakes images; it does **not** update running containers — that's Tidewaiter.
