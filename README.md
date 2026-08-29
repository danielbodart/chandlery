<p align="center"><img src="logo.png" alt="Logo" width="600"></p>


# Chandlery

**Game servers that behave like proper Docker citizens** — where `docker stop`, `docker attach`, `docker ps` health and layer-deduped pulls all just *work*, and the image tag *is* the game version. The image pins the exact version — and refuses to run anything else, so `chandlery/bedrock:1.26.44.3` is exactly Bedrock 1.26.44.3, verified. When a game releases, CI rebuilds the image; graceful stop saves the world before exit; a real health check gates it.

> A *chandlery* is the harbour-side shop that provisions ships for their voyage. This one provisions your servers with their game.

Status: **all three games — Minecraft Bedrock, Valheim, Hytale — are built, proven on a real host, and publishing to GHCR.** The game is *baked into the image at build time*, verified against its checksum, so the tag names an exact, immutable version and `/data` is the only volume. Release CI rebuilds each image on upstream release.

## Running one

```console
$ docker run -d --name bedrock -p 19132:19132/udp -v bedrock-data:/data \
    --stop-timeout 300 ghcr.io/danielbodart/chandlery/bedrock:latest
```

There is a fuller [example compose file](./examples/compose.yaml) with sensible stop grace periods.

Each image documents its own ports, configuration, stop signal and health check
in its folder — ports and lifecycle differ because the three games do:

- [**Bedrock**](./images/bedrock/#readme) — configured by `/data/server.properties`
- [**Valheim**](./images/valheim/#readme) — `VALHEIM_PASSWORD`, then flags via compose `command:`
- [**Hytale**](./images/hytale/#readme) — configured by `/data/config.json`; `/auth login` on the console

A few things worth knowing before the first run:

- **`/data` on a bind mount must be yours.** A named volume just works. A bind mount arrives owned by whoever owns the host directory — `chown 1000:1000` it, or start the container once as root and it will adopt it. Either way it says so rather than failing quietly.

Talk to a running server, or watch its console live, the plain-Docker way — see [Docker-native, all the way down](#docker-native-all-the-way-down) below.

## Docker-native, all the way down

Most game-server images are a shell script that happens to run inside a container: the game is downloaded at runtime, the "console" is a `tmux` or `screen` session bolted on, stopping means a cron-timed save script racing a `SIGKILL`, and "healthy" means "the port is open". Chandlery throws all of that away and lets Docker be the process supervisor it already is. Four things fall out of that.

### Attach and detach — no `tmux`, no `screen`

The container *is* the session. The server's console is on the container's own stdio, so:

```console
$ docker attach chandlery-bedrock          # watch the live console
                                           #   detach with Ctrl-P Ctrl-Q — the game keeps running
$ docker exec chandlery-bedrock chandlery-console say hello   # type a command in from anywhere
```

Detaching leaves the server running because detaching from a container is just… detaching — that is what Docker's attach/detach *is*. There is no multiplexer to install, keep alive, or reattach to across a reboot. The entrypoint wires the server's stdin to a FIFO so `chandlery-console` (and the stop hook) can type at it while `docker attach` watches, and holds that FIFO open for the container's life so the server never reads EOF and quits.

### A stop that means what it says

`tini` is PID 1; the entrypoint is its only child. On `docker stop`, the incoming `SIGTERM` doesn't get blindly forwarded — the entrypoint hands the server its *own* in-band save-and-quit (Bedrock's `stop`, Valheim's `SIGINT`, and so on) and then **waits** for the server to exit on its own terms. A bare `SIGTERM` kills some servers mid-write and loses the world; Chandlery issues the signal the game actually wants.

Because the shutdown honours the timeout Docker already gives it, the grace period is a first-class knob:

```console
$ docker stop chandlery-bedrock            # or: --stop-timeout 300 on run / stop_grace_period in compose
```

`docker restart` covers crashes. No supervisor, no monitor cron, no save-script racing the reaper.

### A health check that speaks the game's protocol

`HEALTHCHECK` is a real Docker directive here, and it runs a *protocol* probe, not a port check — it asks the server the way a player's client would and reads the answer back. So `docker ps` shows `healthy` only when the server is genuinely answering players, `--wait` and compose `depends_on: condition: service_healthy` gate on the truth, and a deployer's rollout can trust it. Where a game gives no in-box probe better than the port-bound check a deployer already runs, Chandlery ships no `HEALTHCHECK` rather than a fake one.

### Layers built for small pulls

The game is baked in at build time, but not as one giant blob. Each image is split into layers *by churn*: the per-release binary rides its own top layer, and the bulk of the assets are bucketed into stable lower layers. The build is **reproducible** — `SOURCE_DATE_EPOCH` and normalised mtimes mean an unchanged subtree bakes to a *byte-identical* layer every time, which is exactly what lets the registry deduplicate it instead of re-shipping the same bytes under a new digest. A version bump then re-pulls only the buckets that actually changed plus the binary — measured on Bedrock, **76.9 MB of a 137 MB image, 20 of 29 layers reused** across a bump. Rolling forward is a small download, not a fresh 137 MB every time.

### Runs as nobody in particular

The server never runs as root. The image ships a `chandlery` user (uid/gid 1000) and starts as it — an ordinary unprivileged container. The one wrinkle Docker itself creates is a bind mount that arrives owned by the host user; for that, start the container as root and the entrypoint adopts `/data`, then `setpriv`-drops to that *same* uid 1000 and execs, landing exactly where the default path starts. Root is a doorway for the mount, never where the game runs.

### `docker inspect` tells the truth

Every image carries the standard `org.opencontainers.image.*` labels — `version` is the game version, `revision` is the repo's git SHA, plus `source`, `description`, `licenses`. So the version is machine-readable the Docker-native way: `docker inspect`, the GHCR web UI, and any registry tooling read it straight off the image without running anything.

### And the tag *is* the version

Existing images take the version as a runtime environment variable, so the same tag runs different software on different days and "roll back" is not an operation you can perform. Chandlery pins the version — and its checksum — in the image at build time. So `:1.26.44.3` is a fact rather than a hope, and rolling back is an ordinary `docker run` of the older tag.

## The fleet

Chandlery is the **build** half of a hands-off homelab: it turns each game release into a versioned image. Its sibling [**tidewaiter**](https://github.com/danielbodart/tidewaiter) is the **deploy** half — it swaps a running container for a newer image *only when the server is idle*, health-gated, with rollback. The loop closes:

> upstream game release → CI rebuilds `image = version` → Tidewaiter deploys it when the tide's out.

The two stay decoupled, though: Chandlery bakes **no** Tidewaiter labels or config into its images. Auto-update policy belongs to whoever is deploying, and Tidewaiter documents its own labels and defaults — better than a copy here that would drift. What the images contribute is a `HEALTHCHECK`, and only where a game gives us a probe that beats the port-bound check a deployer already runs.

Both sit beside [**portical**](https://github.com/danielbodart/portical) in the harbour.

## Why not LinuxGSM / itzg / a panel?

LinuxGSM downloads the game inside the container at runtime, so the image tag says nothing about the version, and its lifecycle is pre-Docker shell. itzg is excellent for Minecraft but Minecraft-only and also runtime-download. Panels install into volumes. None cover **Bedrock + Steam + Hytale** with **image = version + native lifecycle + rebuild-on-release** — because those three games use three different distribution mechanisms. Chandlery unifies them behind one skeleton.

## Working on it

```console
$ make test        # build every image and run the tests against real containers
$ make help        # the other targets
```

The tests drive actual containers, and the fixtures are built to fail honestly: the fake Bedrock server ignores `SIGTERM` and only saves when told `stop` on its console, and the fake Valheim server ignores `SIGTERM` and saves only on `SIGINT`. Wire the stop hook up wrongly and you get a killed container, not a passing test.

`make test-valheim-adapter` covers Valheim's prepare checks, argument assembly, stop signal and health probe without the 1.6 GB download.

## License

Apache-2.0.
