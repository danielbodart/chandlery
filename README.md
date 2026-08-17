![Chandlery Logo](https://raw.githubusercontent.com/danielbodart/chandlery/master/logo.png)


# Chandlery

**Clean-room, Docker-native game-server images where the image tag *is* the game version.** The server is baked in at build time (not downloaded at container start), so `chandlery/bedrock:1.26.44` is exactly Bedrock 1.26.44 — reproducible, pinned, rollback-able. When a game releases, CI rebuilds the image; graceful stop saves the world before exit; a real health check gates it.

> A *chandlery* is the harbour-side shop that provisions ships for their voyage. This one provisions your servers with their game.

Status: **planning** — see [PLAN.md](./PLAN.md).

First three games: **Minecraft Bedrock**, **Valheim**, **Hytale** — a common `tini`-based skeleton plus a per-game source adapter (Mojang download / SteamCMD / Hytale), because that's the one thing that differs between them.

## The fleet

Chandlery is the **build** half of a hands-off homelab: it turns each game release into a versioned image. Its sibling [**tidewaiter**](https://github.com/danielbodart/tidewaiter) is the **deploy** half — it swaps a running container for a newer image *only when the server is idle*, health-gated, with rollback. The loop closes:

> upstream game release → CI rebuilds `image = version` → Tidewaiter deploys it when the tide's out.

The two stay decoupled, though: Chandlery does **not** bake Tidewaiter labels into its images. Auto-update policy belongs to whoever is deploying, so it lives in their compose file — we document the labels and ship an example compose instead. What the images *do* provide is a real `HEALTHCHECK`, which is what a deployer actually needs to gate a swap.

Both sit beside [**portical**](https://github.com/danielbodart/portical) in the harbour.

## Why not LinuxGSM / itzg / a panel?

LinuxGSM downloads the game inside the container at runtime, so the image tag says nothing about the version, and its lifecycle is pre-Docker shell. itzg is excellent for Minecraft but Minecraft-only and also runtime-download. Panels install into volumes. None cover **Bedrock + Steam + Hytale** with **image = version + native lifecycle + rebuild-on-release** — because those three games use three different distribution mechanisms. Chandlery unifies them behind one skeleton. See [PLAN.md](./PLAN.md) for the full comparison and prior-art references.

## License

Apache-2.0.
