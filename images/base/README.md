# base — Chandlery skeleton

The shared skeleton the game images build `FROM`. Deliberately small: `tini` as
PID 1, a non-root `chandlery` user, `/data`, and an entrypoint that stops a server
through its own in-band save-and-quit (via a per-game stop hook) rather than a
bare `SIGTERM` that would lose the world.

Not published or run on its own — the game images (`bedrock`, `valheim`,
`hytale`) bake the game on top of it. See each game's folder for its README.
