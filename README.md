![Chandlery Logo](https://raw.githubusercontent.com/danielbodart/chandlery/master/logo.png)


# Chandlery

**Clean-room, Docker-native game-server images where the image tag *is* the game version.** The image pins the exact version — by URL and checksum, by Steam depot manifest, or by version and patchline — and refuses to run anything else, so `chandlery/bedrock:1.26.44.3` is exactly Bedrock 1.26.44.3, verified. When a game releases, CI rebuilds the image; graceful stop saves the world before exit; a real health check gates it.

> A *chandlery* is the harbour-side shop that provisions ships for their voyage. This one provisions your servers with their game.

Status: **early**. Minecraft Bedrock and Valheim are built and tested, but both currently *bake* the game in and are being converted to pin-and-verify before publication — see [PLAN.md §7.3](./PLAN.md). Nothing is published to a registry yet.

## Running one

```console
$ docker run -d --name bedrock -p 19132:19132/udp -v bedrock-data:/data \
    --stop-timeout 300 ghcr.io/danielbodart/chandlery/bedrock:latest
```

There is a fuller [example compose file](./examples/compose.yaml) with both games, sensible stop grace periods, and the IPv6 network Bedrock insists on.

| | Bedrock | Valheim |
| --- | --- | --- |
| Tag is | the Mojang version | the Steam build id |
| Stops by | `stop` on the server console | `SIGINT` |
| Health check | RakNet ping ([mc-monitor](https://github.com/itzg/mc-monitor)) | Steam `A2S_INFO` |
| Ports | 19132/udp | 2456/udp, 2457/udp (query) |
| Config | `/data/server.properties` | `VALHEIM_*` environment variables |
| Pinned by | versioned URL + sha256 | depot + manifest gid |

Two things worth knowing before the first run:

- **`/data` on a bind mount must be yours.** A named volume just works. A bind mount arrives owned by whoever owns the host directory — `chown 1000:1000` it, or start the container once as root and it will adopt it. Either way it says so rather than failing quietly.
- **Bedrock wants a kernel with IPv6 support** — not IPv6 connectivity. An IPv4-only host is fine. It only matters if IPv6 is disabled outright (`ipv6.disable=1`), where BDS exits complaining its ports are in use when they are not; the image warns about that case.

Talk to a running server with `docker exec chandlery-bedrock chandlery-console say hello`.

## Why pin the version in the image?

Because otherwise the image tag tells you nothing. Existing images take the version as a runtime environment variable, so the same tag runs different software on different days, and "roll back" is not an operation you can perform.

Chandlery bakes the version — and its checksum — at build time, and the container fetches exactly that from upstream on first start or refuses to run. So `:1.26.44.3` is a fact rather than a hope, and rolling back is an ordinary Docker operation.

The images deliberately carry **no game content**: Mojang's EULA and the Steam Subscriber Agreement both prohibit redistributing it, which is why every other image downloads at runtime too. The difference is that ours still knows which version it is.

The rest follows from wanting the lifecycle to be plain Docker: `tini` as PID 1, a stop that hands the server its own in-band save-and-quit and *waits* (Bedrock does not save on a bare `SIGTERM`), a health check that proves the server is answering players rather than merely holding a port, and `restart` for crashes. No supervisor, no tmux, no monitor cron.

## The fleet

Chandlery is the **build** half of a hands-off homelab: it turns each game release into a versioned image. Its sibling [**tidewaiter**](https://github.com/danielbodart/tidewaiter) is the **deploy** half — it swaps a running container for a newer image *only when the server is idle*, health-gated, with rollback. The loop closes:

> upstream game release → CI rebuilds `image = version` → Tidewaiter deploys it when the tide's out.

The two stay decoupled, though: Chandlery bakes **no** Tidewaiter labels or config into its images. Auto-update policy belongs to whoever is deploying, and Tidewaiter documents its own labels and defaults — better than a copy here that would drift. What the images contribute is a `HEALTHCHECK`, and only where a game gives us a probe that beats the port-bound check a deployer already runs.

Both sit beside [**portical**](https://github.com/danielbodart/portical) in the harbour.

## Why not LinuxGSM / itzg / a panel?

LinuxGSM downloads the game inside the container at runtime, so the image tag says nothing about the version, and its lifecycle is pre-Docker shell. itzg is excellent for Minecraft but Minecraft-only and also runtime-download. Panels install into volumes. None cover **Bedrock + Steam + Hytale** with **image = version + native lifecycle + rebuild-on-release** — because those three games use three different distribution mechanisms. Chandlery unifies them behind one skeleton. See [PLAN.md](./PLAN.md) for the full comparison and prior-art references.

## Working on it

```console
$ make test        # build every image and run the tests against real containers
$ make help        # the other targets
```

The tests drive actual containers, and the fixtures are built to fail honestly: the fake Bedrock server ignores `SIGTERM` and only saves when told `stop` on its console, and the fake Valheim server ignores `SIGTERM` and saves only on `SIGINT`. Wire the stop hook up wrongly and you get a killed container, not a passing test.

`make test-valheim-adapter` covers Valheim's prepare checks, argument assembly, stop signal and health probe without the 1 GB SteamCMD download.

## License

Apache-2.0.
