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
- **Layering to keep updates small** — partly measured; see §7.2. What remains is one number, and the tool to get it is written.
- **Steam auth** — public dedicated servers install via `login anonymous`; confirm none of ours need a real account.
- **Base image choice** — alpine vs debian-slim per game (Bedrock's binary wants glibc → debian-slim; Steam games likewise). The base may need to be glibc, not musl.
- **Version marker** for CI "did it change" — newest pushed tag vs a state file.
- Do we generate per-game Dockerfiles from a template (docker-gameserver style) or hand-write three? Three is fine now; template if the count grows.

### 7.1 Hytale: the runtime is solved, the download is not

Investigated against primary sources: the official downloader
(`https://downloader.hytale.com/hytale-downloader.zip`, build `2026.05.13`, its
`QUICKSTART.md` and actual flag set) and Hypixel's
[Server Provider Authentication Guide](https://support.hytale.com/hc/en-us/articles/45328341414043-Server-Provider-Authentication-Guide).

**There are two separate OAuth flows. One is solved by design, the other is
still a blocker — and it is not the one this plan expected.**

#### The server's own authentication: solved, and it suits us

Hypixel documents a first-class provider path, and it is better for Chandlery
than persisting credentials on the volume. A provisioning system authenticates
**once** by device code, keeps the refresh token centrally, and mints per-server
sessions:

1. `POST oauth2/device/auth` (client `hytale-server`, scopes
   `openid offline auth:server`) → device code, once, by a human.
2. `GET account-data.hytale.com/my-account/get-profiles` → profile UUID.
3. `POST sessions.hytale.com/game-session/new` → `sessionToken` + `identityToken`.
4. Start the server with `--session-token` / `--identity-token`, or the
   equivalent `HYTALE_SERVER_SESSION_TOKEN` / `HYTALE_SERVER_IDENTITY_TOKEN`
   environment variables.

That is **token passthrough**, and it means a Hytale image carries no
credentials at all and needs no credential file on `/data` — the deployer
injects two environment variables, exactly the way Valheim takes its password.
A `prepare` hook would check for them and say so plainly when they are missing.
The server refreshes its own game session 5 minutes before the hourly expiry,
falling back to an OAuth refresh, so a running server stays authenticated
indefinitely; re-authentication is only needed after 30 days offline. One
account supports 500 concurrent server sessions, far past a homelab.

Note the rotation rule, because it bites elsewhere: **each OAuth refresh
invalidates the previous refresh token**. Any store of one has to be written
back, never merely read.

#### The download: still no machine credential

The guide does not change this. For server files it points at the same Hytale
Downloader CLI, whose entire flag set is:

```
-check-update  -credentials-path  -download-path  -list-patchlines
-patchline     -print-version     -skip-update-check  -version
```

**No service account, no client-credentials grant, no token flag.** The only
automation hook is `-credentials-path`, pointing at a file produced by an
interactive device login against *a personal Hytale account*, which the tool
rewrites as tokens rotate.

And `-print-version` needs that same credential. That is the sharp end: **we
cannot detect a new Hytale release unattended**, however the download happens.
What is blocked is rebuild-on-release, not bake-at-build.

#### The options, none of which are mine to pick

| | What it costs |
| --- | --- |
| **A. Ask Hypixel whether a machine credential exists for the *downloader*** | Now a narrow, specific question — the runtime side is already answered, so this is the only thing left to ask. Costs a support conversation and an unknown wait. |
| **B. A personal account's credentials file as a CI secret** | Works today. Puts a personal Hytale credential in CI, and the workflow must write the rotated token back to the secret after every run or the next run is locked out. Worth checking against Hytale's terms first. |
| **C. Runtime download**, as every existing Hytale image does | Gives up image = version for this one game — the thing this project exists for. |
| **D. Bake by hand**: a human runs the build locally with their own credentials and pushes the image | Keeps image = version and, combined with token passthrough above, yields a fully working credential-free image that Tidewaiter can swap freely. Gives up only *automatic on release*. |

Recommendation: **D now, A alongside it.** D is no longer a stopgap — with the
runtime solved by token passthrough, a hand-baked Hytale image is a complete,
coherent Chandlery image; the single thing it lacks is noticing a release by
itself. Only A can restore that, and only if such a credential exists.

**Other facts worth carrying forward:** the server is `HytaleServer.jar` +
`Assets.zip` on **Java 25**, wants ~4 GB RAM, and listens on **UDP 5520
(QUIC)** — worth re-checking against Tidewaiter's detectors. It runs on arm64,
though the downloader ships amd64 only. It has a console (`/auth status`,
`/auth logout`), which suits the base skeleton's console FIFO. Sessions should
be terminated on shutdown (`DELETE sessions.hytale.com/game-session`), so
confirm whether the server does that itself before writing a stop hook.

---

### 7.2 Layering: measured, and one number short

Registry blobs are gzipped, so the sizes `docker images` reports are not what a
pull costs. Bedrock 1.26.44.3, read off a real registry manifest:

| layer | compressed |
| --- | --- |
| debian base | 28.2 MB |
| apt (tini, ca-certificates) | 3.9 MB |
| mc-monitor | 6.3 MB |
| game assets | 22.0 MB |
| `bedrock_server` | 76.5 MB |
| **first pull** | **137.0 MB** |

A version bump therefore costs at most 98.5 MB, of which the binary is 78%.
That caps what any cleverness can win at ~22 MB.

**Copying over the top of the previous image does not work the obvious way.**
The layer is a genuine content diff — containerd compares against the parent
snapshot, so rewriting a file with identical content adds nothing. But the
comparison includes mtime, and `unzip` stamps every file it extracts. Measured
on a 40 MB tree where exactly one 2 MB file differed:

| | resulting layer |
| --- | --- |
| `cp -a` (preserves mtimes) | 2.02 MB |
| `cp -r` (fresh mtimes — what `unzip` does) | **40.1 MB** |
| `rsync --checksum` | 2.02 MB |

Mojang rebuilds the whole zip each release and stamps every entry with the
build time, so the naive "download over the top" would land the full payload in
the layer. It needs an explicit `rsync -a --checksum --delete` from a staging
extract.

**But a finer layer split beats chaining anyway.** Splitting the asset tree
into several `COPY` layers along stable boundaries — per pack, say — gives the
same file-level granularity, because an untouched sub-tree keeps its digest and
is not re-pulled. It needs no chain from the previous image, so there is no
growing layer stack against overlay2's 127-layer cap, no periodic squash or
snapshot, no dependency on the previous image still existing, and every build
stays independently reproducible. Chaining buys nothing this does not, and
costs all of that.

**The missing number** is how much of the 22 MB asset tree actually churns
between releases. If the packs change wholesale every time, the current
two-layer split is already optimal and there is nothing to do.
`tools/release-diff` answers it from two release zips — it was written for this
and is unrun, because Mojang's CDN rate-limited the sandbox too hard to fetch a
second release. Run it on any machine with an unthrottled connection, or have
CI publish each release's per-sub-tree digest map as an artifact and let the
history accumulate for free.

---

## 8. Build order (milestones)
1. **Base skeleton**: tini + entrypoint (stop-hook dispatch) + healthcheck dispatch + non-root + /data. A trivial "sleep server" proves stop/health wiring.
2. **Bedrock**: Mojang adapter (baked, drop symbols), stdin-`stop` hook, RakNet health. Replace the LinuxGSM Bedrock servers first (the ones we fought this month).
3. **Bedrock CI**: rebuild-on-Mojang-release, tag=version, push.
4. **Valheim**: SteamCMD adapter (896660), SIGINT stop, A2S health, CI on buildid.
5. **Hytale**: *blocked on a decision, not on work* — see §7.1. Runtime auth is solved (token passthrough, no credentials in the image); the download and version check still need a personal-account OAuth credential. Pick an option there before any Hytale image is written.
6. **Ship + adopt**: publish images, migrate the homelab (`danielbodart/server`) off LinuxGSM one game at a time — configuring Tidewaiter per its own docs, deploy-side (§5).

## 9. Non-goals (v1)
- No mod/plugin management surface (that's itzg's turf for Java — we're not doing Minecraft Java here; itzg stays for Java).
- No panel/UI.
- No multi-host orchestration.
- Chandlery builds & bakes images; it does **not** update running containers — that's Tidewaiter. Nor does it carry Tidewaiter labels, config or documentation: deploy policy is the deployer's, and Tidewaiter documents its own (§5).
