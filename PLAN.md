# Chandlery — design & build plan

> A *chandlery* is the harbour-side shop that provisions ships for their voyage. This one provisions your servers with their game — baked into an image, versioned, ready to sail.

Status: **building**. Milestones 1-4 are done and tested (skeleton, Bedrock, its CI, Valheim); milestone 5 is blocked on a decision (§7.1) and milestone 6 is the homelab migration. This document stays the brief — where it and the code disagree, the code is right and this should be corrected.

---

## 1. What it is

A mono-repo of **clean-room, Docker-native game-server images**, where the **image tag *is* the game version**. Each game's server is installed **at image-build time** (not downloaded at container start), so:

- `chandlery/bedrock:1.26.44` is exactly Bedrock 1.26.44 — reproducible, pinned, rollback-able.
- A new game release triggers a **rebuild** of that image, tagged with the new version + `:latest`.
- The running lifecycle is plain Docker: `tini` as PID 1, a graceful stop that **saves before it exits**, a real health check, `restart` policy for crashes — no bespoke supervisor.

First three games: **Minecraft Bedrock**, **Valheim**, **Hytale**. Structured so more slot in via a small per-game adapter.

This is the **build** half of the fleet; its sibling [`tidewaiter`](https://github.com/danielbodart/tidewaiter) is the **deploy** half — it watches these images and swaps a running container for a newer one *when the server is idle*, health-gated, with rollback. The loop closes end to end, but the two stay decoupled: Chandlery bakes **no** Tidewaiter labels or config into its images — deploy policy is the deployer's, and its details live in Tidewaiter's own docs (see §5). (Both sit beside [`portical`](https://github.com/danielbodart/portical) in the harbour.)

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
    console.sh     #   chandlery-console: type a command at the running server
  bedrock/
    Dockerfile     #   FROM base; MOJANG download baked in; tag = version
    stop-hook      #   write "stop" to the server's stdin (FIFO)
    health         #   RakNet unconnected-ping
  valheim/
    Dockerfile     #   FROM base; steamcmd +app_update 896660 baked in; tag = buildid
    stop-hook      #   forward SIGINT (Valheim saves on SIGINT/SIGTERM)
    health         #   Steam A2S query
  hytale/          # not written: blocked on the decision in 7.1
  test/            # fixtures + tests, driven against real containers
  .github/workflows/
    <game>.yml     #   per-game: poll source version, rebuild+push on change
```

There is no health-check dispatcher in the base. A game image that has a real
probe declares its own `HEALTHCHECK`; one that doesn't declares none, and the
indirection would have earned nothing.

### The base skeleton
- **`tini`** as PID 1 (zombie reaping, clean signal forwarding).
- **Entrypoint** execs the server, and on `SIGTERM` runs the game's **stop hook** (an in-band save+quit) and **waits** for a clean exit, bounded by `stop_grace_period`. This is the itzg/mc-server-runner idea, generalised behind a per-game hook.
- **Non-root user**, world/config on a **`/data`** volume (so a container recreate keeps the world; the game *binaries* live in the image). Started as root (`--user 0`, or a root-owned bind mount) the entrypoint adopts `/data` and drops to the game user, so the normal homelab case works without a chown dance.
- **A console FIFO** wired to the server's stdin and held open for the container's lifetime, so a stop hook — or `docker exec … chandlery-console say hi` — can type at a running server without it seeing EOF.
- **Health check only when we can beat the default.** An image gets a `HEALTHCHECK` *only* if the game gives us a probe that says more than "the port is open" — a protocol-level query that proves the server is actually answering players. Tidewaiter (and any other deployer) already does port-bound checks itself, so a port-bound `HEALTHCHECK` in the image adds a second copy of a check it already has, and a worse one: ours can't see the container's port mapping. When there's no better probe, ship no `HEALTHCHECK` and let the deployer's default do the job.

### Per-game source adapter (build time)
Each game's Dockerfile does one job at build: **install the exact version and bake it in**.
- **Bedrock** — download Mojang's Bedrock dedicated-server zip for a given version, unzip into the image. **Measured, 1.26.44.3:** the ≈311 MB debug-symbols file this plan expected is no longer shipped; what remains to drop is `libMinecraft.Server.Lib.a` (8 MB, for linking against the server, not running it). The zip is 104 MB, 348 MB unpacked, and the finished image is **624 MB** against LinuxGSM's 1.17 GB. The 230 MB `bedrock_server` binary sits in its own layer above the packs, so a version bump re-pulls the binary and reuses the assets.
- **Valheim** — `steamcmd +login anonymous +app_update 896660 validate +quit` at build; bake the result. `validate` makes SteamCMD checksum every file it wrote, which is the nearest thing to a verified artefact Steam offers. The build then re-reads the build id out of `appmanifest_896660.acf` and fails if Steam served a different build from the one asked for. Unlike Bedrock, Valheim takes `-savedir`, so the world simply lives on `/data` with no symlinks.
- **Hytale** — bake the downloaded server; auth is the open question (its download needs OAuth — see §7).

---

## 4. Rebuild-on-release (the "always current" bit)

Per game, a **scheduled CI workflow** (hourly-ish):
1. Resolve the **latest upstream version** — Bedrock: Mojang's version/download endpoint; Valheim: SteamCMD `public` buildid (api.steamcmd.net fast-path, `steamcmd` canonical); Hytale: its release/version source.
2. Compare to the **last built** (the newest image tag, or a recorded marker).
3. If changed: build the image with that version baked in, tag `:<version>` **and** `:latest`, push to Docker Hub + GHCR.

Then Tidewaiter (running on the host) sees the new `:latest` digest and, when the server is empty, pulls + swaps + health-checks + (on failure) rolls back. **Upstream releases → CI rebuilds image=version → Tidewaiter deploys when idle.** Hands-off.

---

## 5. Tidewaiter integration (nothing baked in)

Chandlery images carry **no Tidewaiter labels and no Tidewaiter config**. Two reasons:

- **It isn't ours to decide.** Auto-update policy — which host, which games may swap unattended, what counts as idle — is a deployment decision that changes without the image changing. Baking it in would mean rebuilding an image to change a policy, and would tie a build artefact to one particular deployer.
- **It would go stale.** Tidewaiter's own labels, defaults and health ladder are documented in Tidewaiter, and they'll keep moving. A copy here would be a second source of truth that drifts. For how to configure a deployment, read [tidewaiter](https://github.com/danielbodart/tidewaiter) — not this file.

So the images stay plain: build artefacts any deployer (Tidewaiter, Watchtower, a human, nothing at all) can consume. The one thing Chandlery contributes to the deploy side is a `HEALTHCHECK` — and only where it beats what the deployer would do anyway (§3, §6).

---

## 6. Graceful stop & health, per game

| Game | Stop (save before exit) | `HEALTHCHECK` in the image? |
| --- | --- | --- |
| **Bedrock** | write `stop` to server stdin via a FIFO, wait for exit (BDS does not save cleanly on a bare SIGTERM) | **Yes** — RakNet unconnected-ping via `mc-monitor status-bedrock`; the MOTD reply proves the server is answering |
| **Valheim** | forward `SIGINT` and wait (that is the signal it saves on) | **Yes** — Steam `A2S_INFO` via `chandlery-a2s`, written here: no equivalent single-purpose binary exists, and it handles the challenge/response modern Steam servers require |
| **Hytale** | TBD — determine the server's clean-shutdown command/signal | **No** (for now) — no protocol probe known; port-bound is all we'd have, and the deployer already does that. Add one if a real probe turns up. Blocked behind §7.1 regardless |

The rule for the third column: **add a `HEALTHCHECK` only when we can do better than the deployer's default.** A port-bound check is the default everywhere, so repeating it in the image buys nothing.

Set a generous `stop_grace_period` in the shipped compose so a large world save finishes before Docker sends SIGKILL.

---

### Bedrock needs IPv6, and lies about why

Found while building: BDS binds an IPv6 socket unconditionally. In a container
without IPv6 it fails and reports

> `Port [19132] may be in use by another process`

which sends you hunting a port conflict that does not exist. Hosts booted with
`ipv6.disable=1`, and Docker networks without IPv6, both trigger it. The image's
prepare hook now pre-flights this and says what is actually wrong. Worth
carrying into the homelab's compose: the Bedrock containers need IPv6 in their
network.

---

### What could not be verified in the build sandbox

Both games' *live* behaviour is unproven here, for one shared reason: the
development sandbox's kernel has IPv6 disabled outright.

- **Bedrock** binds an IPv6 socket unconditionally and exits without one, so
  BDS has never actually been started. Everything around it is tested — the
  bake, the layout, the health probe against a fake RakNet responder — but the
  first real run is still ahead.
- **Valheim** cannot even be *built* there: SteamCMD fails with
  `EAFNOSUPPORT` creating its IPv6 socket, so the download never begins. The
  adapter is tested instead against a fake server carrying the real scripts
  (password checks, argument assembly, the SIGINT stop, the A2S probe), which
  covers everything except SteamCMD itself.

Neither is expected to affect a normal host; both want a real run before the
homelab migration in §8.6.

---

## 7. Open questions (resolve in build)
- **Hytale auth in CI** — investigated; see §7.1. It now needs a decision, not more investigation.
- **Layering to keep updates small.** Split each Dockerfile so rarely-changing assets sit in a lower layer and the volatile binary in the top layer, so a version bump re-pulls only the small layer (helps MC a lot; Steam's `app_update` rewrites broadly, so gains are limited — measure).
- **Steam auth** — public dedicated servers install via `login anonymous`; confirm none of ours need a real account.
- **Base image choice** — alpine vs debian-slim per game (Bedrock's binary wants glibc → debian-slim; Steam games likewise). The base may need to be glibc, not musl.
- **Version marker** for CI "did it change" — newest pushed tag vs a state file.
- Do we generate per-game Dockerfiles from a template (docker-gameserver style) or hand-write three? Three is fine now; template if the count grows.

### 7.1 Hytale: what the OAuth question turned out to be

Investigated against primary sources — the official downloader
(`https://downloader.hytale.com/hytale-downloader.zip`, build `2026.05.13`,
its `QUICKSTART.md` and its actual flag set). Hypixel's own *Server Provider
Authentication Guide* is the one document that could change the answer and it
sits behind Cloudflare, unreadable from here.

**There are two separate OAuth flows, and only one of them is a problem.**

*The server's own login is not the blocker.* A Hytale server authenticates
itself (`/auth login device`) before it will accept players. That sounds fatal
for hands-off deployment, but the credentials persist on the data volume and
refresh themselves, so once a server has logged in, restarts — and image swaps
— need no login at all. Tidewaiter's half of the loop is fine.

*The download is the blocker.* The downloader offers exactly these flags:

```
-check-update  -credentials-path  -download-path  -list-patchlines
-patchline     -print-version     -skip-update-check  -version
```

There is **no service account, no client-credentials grant, no token flag**.
The only automation hook is `-credentials-path`, pointing at a file produced by
an interactive device login against *a personal Hytale account*. Worse, the
tool rewrites that file as tokens refresh, and its own guide warns that an
automated caller must retain the updated file — so a CI secret would have to be
written back after every run.

And `-print-version` needs the same credential. That is the sharp end: **we
cannot even detect a new Hytale release unattended**, whichever way the
download happens. Rebuild-on-release, not just bake-at-build, is what is
actually blocked.

**The options, none of which are mine to pick:**

| | What it costs |
| --- | --- |
| **A. Ask Hypixel for a provider credential** | Best outcome, and the *Server Provider Authentication Guide* suggests such a path may exist. Costs a support conversation and an unknown wait. |
| **B. A personal account's credentials file as a CI secret** | Works today. Puts a personal Hytale credential in CI, needs the workflow to write the refreshed token back to the secret after each run, and is worth checking against Hytale's terms before doing. |
| **C. Runtime download**, as every existing Hytale image does | Gives up image = version for this one game — the thing this project exists for. |
| **D. Bake by hand**: a human runs the build locally with their own credentials and pushes the image | Keeps image = version, gives up *automatic on release*. Cheapest honest option while A is pending. |

Recommendation: pursue **A**, run **D** in the meantime. Do not build a Hytale
image until this is settled — the choice changes what the image is.

**Other facts worth carrying forward** (secondary sources, unverified without
an account): the server is `HytaleServer.jar` + `Assets.zip` on **Java 25**,
wants ~4 GB RAM, and listens on **UDP 5520 (QUIC)** — not the plan's assumed
`conntrack`-friendly shape, and worth re-checking against Tidewaiter's
detectors. The server runs on arm64, but the downloader ships amd64 only.

---

## 8. Build order (milestones)
1. **Base skeleton**: tini + entrypoint (stop-hook dispatch) + healthcheck dispatch + non-root + /data. A trivial "sleep server" proves stop/health wiring.
2. **Bedrock**: Mojang adapter (baked, drop symbols), stdin-`stop` hook, RakNet health. Replace the LinuxGSM Bedrock servers first (the ones we fought this month).
3. **Bedrock CI**: rebuild-on-Mojang-release, tag=version, push.
4. **Valheim**: SteamCMD adapter (896660), SIGINT stop, A2S health, CI on buildid.
5. **Hytale**: *blocked on a decision, not on work* — see §7.1. The download and even the version check need a personal-account OAuth credential; pick an option there before any Hytale image is written.
6. **Ship + adopt**: publish images, migrate the homelab (`danielbodart/server`) off LinuxGSM one game at a time — configuring Tidewaiter per its own docs, deploy-side (§5).

## 9. Non-goals (v1)
- No mod/plugin management surface (that's itzg's turf for Java — we're not doing Minecraft Java here; itzg stays for Java).
- No panel/UI.
- No multi-host orchestration.
- Chandlery builds & bakes images; it does **not** update running containers — that's Tidewaiter. Nor does it carry Tidewaiter labels, config or documentation: deploy policy is the deployer's, and Tidewaiter documents its own (§5).
