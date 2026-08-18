# Chandlery — design & build plan

> A *chandlery* is the harbour-side shop that provisions ships for their voyage. This one provisions your servers with their game — pinned to an exact version in the image, fetched and verified on first start, ready to sail.

Status: **all three games built, proven on a real host, and publishing to GHCR.** The images are **pinned, not baked**: each records exactly which version and fetches those bytes from upstream on first start through a shared `chandlery-cache` helper (atomic, marker-last, fail-closed), so a public image redistributes no game content (§7.3). Where each game stands:

- **Bedrock** — pins the Mojang URL + sha256. Proven end to end: fetch → sha256 verify → BDS boots healthy (RakNet probe) → graceful stop saves → cache reuse → wrong-sha fails closed. `chandlery/bedrock:1.26.44.3` on GHCR; hourly release CI.
- **Valheim** — pins the depot manifest gid, fetched with **DepotDownloader** under the operator's own licensed Steam account (anonymous cannot download this depot, and rollback needs old manifests — both verified on a real host). The tag is the real **game version** (0.221.12), read by booting the server; build id and gid are labels. steamclient.so is kept current by SteamCMD (the depot's own is too old). Boots, connects to Steam, A2S-healthy, saves on SIGINT. CI reads the version and pushes `chandlery/valheim:<version>`.
- **Hytale** — pins version + patchline; the operator's OAuth token fetches their entitled copy at start (token passthrough, no credentials in the image). Java 25 (Temurin, pinned), auto-updater disabled. The download flow is verified against the official downloader's live traffic (§7.1) — a Cloudflare-R2 signing proxy returning `{version, download_url, sha256}`, so Hytale gets a sha256 pin too. `hytale.yml` is live (authenticated version detect; refresh-token rotation written back via a GitHub App). Proven on a real host: 1.5 GB fetch → Java boots → console `/stop` saves → exit 0. `chandlery/hytale:0.5.9` on GHCR.

The credential story is symmetric: Bedrock needs none; Valheim needs a Steam account token; Hytale needs a downloader token — each injected at runtime, none baked. `tools/hytale-token` mints/rotates Hytale's.

**Remaining: milestone 7, the homelab migration** off LinuxGSM. This document stays the brief — where it and the code disagree, the code is right and this should be corrected.

---

## 1. What it is

A mono-repo of **clean-room, Docker-native game-server images**, where the **image tag *is* the game version**. The image **pins** the exact version — by URL and checksum, by Steam depot manifest, or by version and patchline — and refuses to run anything else, so:

- `chandlery/bedrock:1.26.44.3` is exactly Bedrock 1.26.44.3 — pinned, verified, rollback-able.
- A new game release triggers a **rebuild** of that image, tagged with the new version + `:latest`.
- The running lifecycle is plain Docker: `tini` as PID 1, a graceful stop that **saves before it exits**, a real health check, `restart` policy for crashes — no bespoke supervisor.

The images ship **no game content**. That is a licensing constraint, not a design
preference, and §7.3 explains it. The version is **pinned**; the bytes are fetched
from upstream on first start and verified against that pin, which fails closed if
they do not match. The distinction that matters is against the runtime-download
images this project was started to replace: there the version is an environment
variable and the tag tells you nothing, so the same tag runs different software on
different days. Here the pin is cryptographic and the tag cannot lie.

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
- **[docker-gameserver](https://github.com/GameServerManagers/docker-gameserver)** (LinuxGSM's own) — its Jinja-templated per-game Dockerfiles from one base is the *structure* to emulate. We take the structure but **pin the version in the image** and fetch-verify on first start, rather than downloading whatever an env var names.
- **[SteamRE/DepotDownloader](https://github.com/SteamRE/DepotDownloader)** — downloads a Steam depot by immutable manifest gid under a real account, with a portable token. This is how Valheim fetches (anonymous SteamCMD cannot, and it cannot pin old manifests for rollback).
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
    Dockerfile     #   tini as PID 1, entrypoint framework, non-root user, /data + /cache
    entrypoint.sh  #   runs the server; on SIGTERM runs the game's stop-hook, waits
    console.sh     #   chandlery-console: type a command at the running server
    cache.sh       #   chandlery-cache: fetch a pinned payload to /cache once, atomically
  bedrock/         # FROM base; pins Mojang URL + sha256; tag = version
    fetch prepare run stop-hook health upstream-version
  valheim/         # FROM base; pins depot manifest gid; tag = game version
    fetch (DepotDownloader) run prepare stop-hook health game-version upstream-version probe/
  hytale/          # FROM base; pins version + patchline; tag = version
    fetch prepare run stop-hook upstream-version
  tools/
    hytale-token   #   mint/rotate the Hytale downloader token (host + CI)
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

### Per-game source adapter (pin at build, fetch on first start)
Each game's Dockerfile records **which** version, precisely enough it cannot run
anything else; the base's `chandlery-cache` helper fetches those bytes onto the
`/cache` volume on first start, verified, and reuses them thereafter. This is
the pin-not-carry design §7.3 forces; the helper is shared so all three games
(and Hytale's 3.3 GB assets especially) fetch through one atomic, fail-closed,
marker-last engine.
- **Bedrock** — the image pins the versioned Mojang URL and its **sha256**, both
  as image env. The `fetch` hook downloads the zip, checks it against that
  sha256 (a mismatch refuses to start, never runs), unzips, and drops the static
  link library and the old debug-symbols file. The finished image is **161 MB**
  (was 624 MB baked); the ≈104 MB zip lands on `/cache`, not in a layer. BDS has
  no config-path flag, so its four stateful paths are seeded onto `/data` from
  the fetched tree, then symlinked out to it.
- **Valheim** — the image pins the depot (896661) and the immutable **manifest
  gid**. Anonymous SteamCMD *cannot* download this depot ("No subscription"), so
  `fetch` uses **DepotDownloader** under the operator's own licensed Steam account
  (its portable token injected at runtime), downloading exactly that manifest.
  Pinning the manifest is what makes **rollback** possible: an old gid still
  fetches its exact bytes, verified on a real host. The tag is the real game
  version (read by booting the server, since Steam only exposes a build id); build
  id and gid are labels. SteamCMD is baked only for a *current* `steamclient.so`
  (the depot's own is too old for the server's Steam init). Valheim takes
  `-savedir`, so the world lives on `/data` with no symlinks.
- **Hytale** — pins version + patchline; the operator's own OAuth token fetches
  their own entitled copy at start (§7.1, §7.3). No content in the image, so no
  redistribution question for it at all.

---

## 4. Rebuild-on-release (the "always current" bit)

Per game, a **scheduled CI workflow** (hourly-ish):
1. Resolve the **latest upstream version** — Bedrock: Mojang's download-links endpoint; Valheim: the `public` branch build id + manifest gid from api.steamcmd.net; Hytale: the authenticated version manifest (`tools/hytale-token` for the token).
2. Compare to the **last built** — the newest image tag, or a cheap marker (Valheim keys off a `build-<id>` tag, since its human tag is the game version it does not yet know).
3. If changed: build the image pinning that version, tag `:<version>` **and** `:latest`, push to **GHCR** (public; §8 explains why GHCR alone). Valheim additionally downloads and boots the server to read its game version for the tag.

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
| **Hytale** | write `/stop` to the console via the FIFO, wait for exit (verified on a live 0.5.9 server: it saves config and world, then exits 0; no SIGTERM handler) | **No** — no protocol probe ships in the box; port-bound is all we'd have, and the deployer already does that. Add one if a real probe turns up |

The rule for the third column: **add a `HEALTHCHECK` only when we can do better than the deployer's default.** A port-bound check is the default everywhere, so repeating it in the image buys nothing.

Set a generous `stop_grace_period` in the shipped compose so a large world save finishes before Docker sends SIGKILL.

---

### Bedrock opens an IPv6 socket, and lies when it cannot

BDS creates an IPv6 socket whether or not anything routes over it. When it
cannot, it reports

> `Port [19132] may be in use by another process`

and exits, which sends you hunting a port conflict that does not exist.

**This needs IPv6 *support* in the kernel, not IPv6 connectivity.** An IPv4-only
host is fine — the homelab runs BDS on IPv4 today. It only bites where IPv6 has
been compiled out or switched off outright (`ipv6.disable=1`), which is what the
build sandbox did and which is unusual. The prepare hook warns about that case
rather than refusing to start, since the message is the useful part.

---

### What is proven, and where

All three games have now been run for real on a normal host (an IPv6-capable
desktop; the original build sandbox had IPv6 disabled, which is why earlier
drafts of this section listed everything as unproven).

- **Bedrock** — fetched from Mojang against the pinned sha256, unzipped, BDS
  booted (IPv4 and IPv6 sockets both bound), the RakNet HEALTHCHECK went healthy,
  a `docker stop` drove the console `stop` to a clean save and exit 0, a restart
  took the cache fast path, and a wrong sha256 failed closed leaving nothing on
  `/cache`.
- **Valheim** — the DepotDownloader fetch pulled both the current and an old
  manifest (rollback), the server booted, connected to Steam (with a current
  `steamclient.so` — the depot's own is too old), answered A2S (healthy), and
  saved on SIGINT (exit 0). CI reads the game version by booting a staging server.
- **Hytale** — the 1.5 GB build fetched (sha256-verified), Java 25 booted it in
  offline mode, and `docker stop` → the console `/stop` saved and exited 0.

The adapters are *also* covered by fake-server fixtures (password/token checks,
argument assembly, the stop signal, the health probe) so the fast test suite
needs no multi-gigabyte download. The one thing still ahead is the homelab
migration itself (§8).

---

## 7. Open questions — now mostly resolved
- **Hytale auth in CI** — **resolved.** `hytale.yml` is live: device-login once, a rotating refresh token in CI, written back via a GitHub App (§7.1).
- **Layering to keep updates small** — **moot.** Pin-not-carry means the images are tens of MB with no game-binary layers to be clever about (§7.2, §7.3).
- **Steam auth** — **resolved, and the opposite of what this hoped.** Anonymous *cannot* `download_depot` this depot ("No subscription"), and rollback needs old manifests, so Valheim fetches with DepotDownloader under a real licensed account (§7.3).
- **Base image choice** — **resolved.** debian-slim (glibc) throughout; Bedrock's binary and SteamCMD both want glibc.
- **Version marker** for CI "did it change" — **resolved.** Newest pushed tag (Bedrock/Hytale), or a cheap `build-<id>` marker tag for Valheim, whose human tag is the game version it does not yet know.
- **Template vs hand-write** — hand-written three; template only if the count grows.

### 7.1 Hytale: both the runtime and the download are solved

Investigated against primary sources: the official downloader
(`https://downloader.hytale.com/hytale-downloader.zip`, build `2026.05.13`, its
`QUICKSTART.md` and actual flag set) and Hypixel's
[Server Provider Authentication Guide](https://support.hytale.com/hc/en-us/articles/45328341414043-Server-Provider-Authentication-Guide).
This section began as an open investigation; it is kept because the reasoning is
useful, but the outcome is now **built and running** — `hytale.yml` ships
`chandlery/hytale:0.5.9` and a real host runs it.

**There are two separate OAuth flows, both solved.** The server's own session is
token passthrough; the download is a device login once, then a rotating refresh
token — and the download flow is now mapped against live traffic, not inferred.

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

#### The download: not blocked after all

An earlier draft of this section called the download blocked because the CLI has
no `client_credentials` grant. That was the wrong test. **Device code *is* the
automation story** — Hypixel's own provider guide opens with "obtain tokens once,
use the Device Code Flow to get a `refresh_token`". There is no separate machine
credential because none is intended: you log in by hand once, and hold the
refresh token forever.

And nothing obliges us to use their CLI. The binary hands us the whole map, and
the flow answers to a plain `curl`:

```console
$ curl -X POST https://oauth.accounts.hytale.com/oauth2/device/auth \
    -d client_id=hytale-downloader -d "scope=openid offline auth:downloader"
{"device_code":"ory_dc_...","user_code":"fkYMjXa6",
 "verification_uri":"https://oauth.accounts.hytale.com/oauth2/device/verify",
 "expires_in":599,"interval":5}
```

Verified: HTTP 200, a real code. And the whole download flow is now mapped, by
intercepting the official downloader's own traffic (mitmproxy, Go trusting the
CA via `SSL_CERT_FILE`) — so this is confirmed, not inferred:

1. `GET account-data.hytale.com/game-assets/version/<patchline>.json` (Bearer)
   returns `{"url": <signed Cloudflare-R2 URL>}` — a **signing proxy**: ask it
   for any object under `game-assets/`, it hands back a signed R2 URL.
2. `GET <signed url>` returns the manifest:
   `{"version":"0.5.9","download_url":"builds/release/0.5.9.zip","sha256":"…"}`.
3. `GET account-data.hytale.com/game-assets/<download_url>` (Bearer) →
   `{"url": <signed url>}`; `GET` that → the build zip (release 0.5.9 is
   **1,523,827,231 bytes**, `application/zip`). The manifest's `sha256` verifies
   it — so **Hytale gets a cryptographic pin like Bedrock**, not just a version
   string. `hytale/fetch` drives exactly this; `hytale/upstream-version` reads
   the manifest for the version, sha256 and download path. We own token
   persistence (`tools/hytale-token`) rather than inheriting the CLI's
   credentials file. Version check *and* rebuild-on-release are both in hand.

Note the earlier draft's `account-data.hytale.com/version/<patchline>.json` was
wrong — the real path is under `game-assets/`, and returns a signed-URL wrapper,
not the manifest directly.

What survives from the pessimistic version is one operational hazard, not a
blocker: **the refresh token rotates on every use and the old one dies**. CI has
to write the new token back to its secret before doing anything else with it, or
an interrupted run locks the pipeline out until a human repeats the device login.
A concurrency group is mandatory — two runs refreshing at once and one of them
loses. That is a thing to engineer carefully, and it is well-trodden.

#### The question that actually remains: redistribution

Every Hytale download is gated behind a per-account OAuth flow and a signed,
per-request URL. An image on a public registry hands those bytes to anyone who
pulls it, gate and all. That is a licensing question rather than a technical one,
and it is the real obstacle to a public `chandlery/hytale` — not the auth.

It deserves asking of the other two as well, before this project's images go
anywhere public. It may be exactly why itzg and LinuxGSM both download at
runtime rather than baking: doing so keeps the redistribution with the
publisher and out of the image. Baking is what makes this project worth
building, so the answer matters. It is a decision for a human, and possibly one
for Hypixel's support team.

A private registry sidesteps it entirely, and the homelab in §8.6 is private.

#### Verified against the binary and the live endpoints

The downloader ships unstripped with debug info, so this is not guesswork.

- Its OAuth client is `hytale-downloader`, scopes `openid offline
  auth:downloader`, and the only grants compiled in are `device_code` and
  `refresh_token` — which, per above, is all the flow needs.
- The endpoints: `oauth.accounts.hytale.com/oauth2/{auth,device/auth,token}`;
  `account-data.hytale.com` for `my-account/get-patchlines` and
  `version/<patchline>.json`; game assets via a signed URL requested per
  download.
- **Everything about the game is authenticated.**
  `account-data.hytale.com/my-account/get-patchlines` answers
  `403 invalid authorization header` unauthenticated. The one public endpoint,
  `downloader.hytale.com/version.json`, reports the version of **the downloader
  itself** (`{"latest": "2026.05.13-99ade04"}`), not the game's. So a token is
  needed even to notice a release — but a token is exactly what the device flow
  gives us.
- The published archive is
  `sha256 9f6939cce346d2ad09490728bbd4b8a5bbe5cb3fd7f3934f2b52e3f2fa0b0aaf`
  (build `2026.05.13-99ade04`), byte-identical to a copy downloaded
  independently — worth pinning if a build ever shells out to it.
- Also present in the binary: an `account-data.arcanitegames.ca` host string,
  alongside the hytale.com one. Noted, not investigated.

#### Where that leaves it

| | Status |
| --- | --- |
| Server runtime auth | **Solved.** Token passthrough; the image carries no credentials. |
| Downloading and version-checking | **Solved and running.** One device login by hand, then a rotating refresh token in CI, written back via a GitHub App. We wrote the client; the CLI is not used. |
| Publishing publicly | **Resolved by the same logic as the other two:** the image carries no game content (pin-not-carry), so there is nothing to redistribute — the operator's own token fetches their entitled copy at start. |
| Clean shutdown | **Solved.** The console `/stop` command saves and exits 0, verified on a live 0.5.9 server; the stop hook sends it on SIGTERM. |

#### What the image looks like — as built

From the
[Server Manual](https://support.hytale.com/hc/en-us/articles/45326769420827-Hytale-Server-Manual);
this is what the image does.

**The server ships its own auto-updater, and we have to turn it off.** It polls
hourly, stages a download, exits with code 8, and a wrapper script swaps the
files in and restarts. Its `AutoApplyMode: WhenEmpty` applies the update *when
no players are online* — which is, precisely, Tidewaiter's job, built into the
game. For Chandlery it is not a feature but a hazard: a container that rewrites
its own binaries has quietly stopped being the version on its tag. Set
`HYTALE_DISABLE_UPDATES` (or `Update.Enabled: false`), run the jar directly
rather than through `start.sh`, and let CI and the deployer do what they do for
the other two games. Worth a look at `WhenEmpty` as prior art for Tidewaiter
regardless.

**`/data` is easier than Bedrock's.** The server writes `universe/` (worlds and
players), `config.json`, `permissions.json`, `bans.json`, `whitelist.json`,
`logs/`, `mods/` and `.cache/` relative to its working directory, and `--assets`
takes a path. So the jar and assets live in the image, the working directory is
`/data`, and everything lands on the volume with no symlinks.

**It is a big image.** `Assets.zip` alone is **3.3 GB** — five times the whole
Bedrock image. That makes §7.2's layering question sharper here than anywhere
else: assets that large, changing rarely, want a layer of their own.

**Health:** no protocol probe in the box. Hypixel points at a third-party
`Nitrado:Query` plugin that exposes status over HTTP, which would qualify under
§3's rule; without it, ship no `HEALTHCHECK` and let the deployer's port-bound
check stand. QUIC over UDP 5520 by default (`--bind`), which is what Tidewaiter's
detector has to cope with.

**Odds and ends:** Java 25, arm64 as well as x64, ~4 GB RAM minimum, and a
pre-trained AOT cache (`-XX:AOTCache=HytaleServer.aot`) worth using for boot
time. `--auth-mode offline` exists, which makes a LAN or test server possible
with no credentials at all — useful for our own tests. `--disable-sentry` stops
crash reports going to Hypixel. The manual documents no clean-shutdown command,
so the stop hook still needs establishing; the console that `/auth` and
`/update` use suits the base skeleton's FIFO.

**Other facts worth carrying forward:** the server has a console (`/auth
status`, `/auth logout`), and sessions should be terminated on shutdown
(`DELETE sessions.hytale.com/game-session`) — confirm whether the server does
that itself before writing a stop hook.

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

### 7.3 Licensing, and the design it forces

**Decision taken: the images are published publicly.** Everything below follows
from that, because publishing publicly and baking game content are not
compatible.

#### What the terms say

Not legal advice — but all three read the same way, and one of them is explicit.

- **Bedrock.** The [Minecraft EULA](https://www.minecraft.net/en-us/eula): you
  "must not distribute anything we've made", spelled out as "give copies of our
  game software or content to anyone else". No dedicated-server carve-out.
  [itzg's image](https://github.com/itzg/docker-minecraft-bedrock-server) states
  plainly that "the Bedrock server software is not bundled into this image",
  and every serious Bedrock image does the same — which is its own evidence.
- **Valheim.** The
  [Steam Subscriber Agreement](https://store.steampowered.com/subscriber_agreement/)
  is explicit: you "may not, in whole or in part, copy… reproduce, publish,
  distribute" Content without Valve's prior written consent, and are "not
  entitled to… transfer reproductions of the Content and Services to other
  parties in any way". The dedicated-server clause grants *use* on unlimited
  machines, not distribution.
- **Hytale.** Every download is gated behind per-account OAuth and a signed,
  per-request URL (§7.1). A public image would hand those bytes to anyone who
  pulls it, gate and all.

A private registry would sidestep all of this — copying for your own machines is
much closer to ordinary use. That option is now closed by the decision above.

#### The design that survives: pin, don't carry

The image records **which** version, precisely enough that it cannot run
anything else, and fetches the bytes from upstream on first start. This is not
the runtime-download model it superficially resembles:

| | version comes from | can the tag lie? |
| --- | --- | --- |
| LinuxGSM, itzg | a runtime environment variable | yes — same tag, different software |
| **Chandlery** | **baked at build, verified on fetch** | **no — it fails instead** |

What is kept: tag = version, rebuild-on-release, rollback, and a checksum that
makes the pin cryptographic. What is given up: self-contained images, offline
start, and a fast first boot. Cache the payload on `/data` and only the first
start of a given version pays.

It needs no new architecture — the base skeleton's `prepare` hook already runs
before the server starts, and fetch-verify-extract is exactly what it is for.

#### Each game has a version-addressed handle. They just look different.

| game | what the image pins | how the bytes are fetched |
| --- | --- | --- |
| **Bedrock** | the versioned URL + **sha256** | plain HTTPS; old versions stay up (1.26.42.1 and 1.26.43.1 both still 200) |
| **Valheim** | depot + **manifest gid**, e.g. `896661:962159520942340660` | `DepotDownloader -depot 896661 -manifest <gid>` under a licensed Steam account |
| **Hytale** | version + patchline | the operator's own OAuth token buys a signed URL at start |

Content on Steam is addressed by **immutable depot manifests** (depot `896661`
is the Linux server); pinning the manifest makes a Valheim build *reproducible*
and — crucially — makes **rollback** possible, since an old gid still fetches its
exact bytes. Both were verified on a real host: DepotDownloader pulled the
current manifest and a four-month-old one.

Two things this plan flagged to verify are now answered, and the first was a
surprise:

- **Anonymous cannot download this depot.** `steamcmd +login anonymous
  +download_depot 896660 896661 <gid>` fails with *"missing license for depot
  (No subscription)"*, even after `app_license_request`. `app_update` works
  anonymously but only serves the *current* build, so it cannot pin an old
  manifest — no rollback. So Valheim fetches with **DepotDownloader** under the
  operator's own **licensed** account. Its login is a portable ~640-byte token
  (no per-run 2FA, works across machines and CI — unlike a machine-bound SteamCMD
  sentry), injected at runtime; the image carries none.
- **Old manifests stay downloadable.** Iron Gate does not block them (Steam lets
  developers, but they haven't), so rollback is real. `api.steamcmd.net` reports
  only the *current* gid, so **CI records the gid it used** on every build; our
  own history keeps every published image re-creatable.

Two more Valheim facts this cost us on the way, both fixed: the depot's bundled
`steamclient.so` is from 2022 and the current server rejects it ("Missing
interface adapter for SteamGameServer015"), so SteamCMD supplies a current one
at runtime; and the game version (the human tag) is a code constant with no
static source, so CI reads it by booting the server.

#### Hytale works under this model, today

Nothing has to change for it. The image carries no game content, so there is no
redistribution question; it records version and patchline, and at start the
operator's own credential fetches their own entitled copy — the same shape as
the `HYTALE_SERVER_SESSION_TOKEN` passthrough the server already needs. Unlike
Bedrock there is no URL to record, because Hytale's asset URLs are signed and
per-request; the version is the pin, and the URL is resolved at runtime.

One wrinkle remains: **CI still needs a credential to *detect* a release**, since
the version manifest is authenticated (§7.1). That is an authenticated GET of a
version number — no bytes, no redistribution — but it still means a rotating
refresh token in CI, handled as §7.1 describes.

#### Consequences — now carried out

- **Bedrock and Valheim were converted from baking to pin-and-fetch**, and all
  three games publish to GHCR. This is what made them publishable at all.
- **§7.2's layering question evaporated.** A thin image is tens of megabytes;
  there are no game-binary layers to be clever about. `tools/release-diff` stays
  useful for understanding upstream churn, but it no longer gates anything.
- **The registry decision got easier** — GHCR only, public (§8).

---

## 8. Build order (milestones)

**Milestones 1–6 are done** — all three games are built, pin-and-fetch, proven on
a real host, and publishing to GHCR with live release CI. Milestone 7 (the homelab
migration) is what remains. The steps below are the original plan; a few describe
a "baked" intermediate that milestone 6 then converted.

1. **Base skeleton**: tini + entrypoint (stop-hook dispatch) + non-root + /data + /cache. A trivial "sleep server" proves stop/health wiring.
2. **Bedrock**: Mojang adapter (baked, drop symbols), stdin-`stop` hook, RakNet health. Replace the LinuxGSM Bedrock servers first (the ones we fought this month).
3. **Bedrock CI**: rebuild-on-Mojang-release, tag=version, push.
4. **Valheim**: SteamCMD adapter (896660), SIGINT stop, A2S health, CI on buildid.
5. **Hytale**: buildable — see §7.1. Runtime auth is solved (token passthrough, no credentials in the image) and the download needs one device login by hand, then a rotating refresh token. Open before *publishing*: whether baking gated assets into a public image is redistribution (§7.1), which applies to Bedrock and Valheim too.
6. **Convert Bedrock and Valheim to pinned-not-baked** (§7.3), which is what makes them publishable. Bedrock pins URL + sha256; Valheim pins depot + manifest gid, which also makes its builds reproducible.
7. **Ship + adopt**: publish to **GHCR only**, migrate the homelab (`danielbodart/server`) off LinuxGSM one game at a time — configuring Tidewaiter per its own docs, deploy-side (§5).

### Registry: GHCR, public, and nothing else

Public packages on GHCR are free with no storage or transfer limit, and CI
pushes to them with the automatic `GITHUB_TOKEN` — **no credential to create,
store or rotate**. Docker Hub needs a username and token as repository secrets
and buys nothing we do not already have, so it is dropped rather than left as a
disabled branch in the workflows.

For contrast, had the images stayed private: GitHub Free allows 500 MB of
package storage (shared with Actions artifacts) and 1 GB of transfer a month.
Bedrock alone was 137 MB per pull when baked — about four versions before the
quota is gone, against a project whose whole point is keeping old versions to
roll back to. Public is not just simpler here, it is the only free option that
fits. Pinned images are tens of megabytes anyway, so neither limit would bite
now; the reasoning is recorded in case the images ever go private.

## 9. Non-goals (v1)
- No mod/plugin management surface (that's itzg's turf for Java — we're not doing Minecraft Java here; itzg stays for Java).
- No panel/UI.
- No multi-host orchestration.
- Chandlery builds & bakes images; it does **not** update running containers — that's Tidewaiter. Nor does it carry Tidewaiter labels, config or documentation: deploy policy is the deployer's, and Tidewaiter documents its own (§5).
