# Chandlery on plain systemd

The same game servers as the Docker images, without Docker: each one a
hardened systemd service with the lifecycle the images give a container. A
console you can type at, a stop that saves the world before it exits, and
readiness that means the game is actually up. The game comes out of the
published image, so the version you run is exactly the one the image pins.

This page is for any systemd distribution. On NixOS, use the flake's module
instead ([NixOS](#nixos) below): it renders the same units with options for
everything here, and confines each server to its own closure.

## What you get

For a server called `<name>`:

| | |
|---|---|
| `chandlery@<name>.service` | the game, `Type=notify`: *active* only once the game logs that it is up |
| `chandlery@<name>.socket` | its console, a FIFO at `/run/chandlery/<name>/console` that the game reads as its stdin |
| `/var/lib/chandlery/<name>` | its world and config, which the game sees as `/data`, as in the image |
| `/var/lib/chandlery-packages/<name>` | the game: a package `chandlery-unpack` laid out (usually a symlink to one) |
| `/etc/chandlery/<name>.env` | its settings (optional) |
| `chandlery-console <name> <command>` | type one line at its console, e.g. `chandlery-console wrlin say hello` |
| `chandlery-console <name>` | follow its log and type at it (Ctrl-C leaves; the server keeps running) |

`systemctl stop chandlery@<name>` types the game's own save-and-quit at its
console (Bedrock's `stop`, Hytale's `/stop`) and waits up to five minutes for
it to exit. Valheim saves on `SIGINT`, so that is the signal it gets. It is
`docker stop` with the image's stop hook, under systemd.

## Install

You need systemd 252 or newer (257 or newer for `PrivatePIDs=`; older ones
ignore it with a warning), Go to build two small helpers, and on the host
`curl`, `jq`, `tar`, `gzip`, `zstd`, `flock` (util-linux), `awk` and `cmp`.

```console
$ git clone https://github.com/danielbodart/chandlery && cd chandlery
$ sudo make install-systemd              # PREFIX=/usr/local; DESTDIR for packagers
$ sudo systemd-sysusers                  # creates the `chandlery` user
$ sudo systemctl daemon-reload
```

That installs `chandlery-{ready,notify,prepare,stop,console,unpack,set-property,make-data-dir}`
to `/usr/local/bin`, the templates to `/etc/systemd/system`, and
`/etc/sysusers.d/chandlery.conf`.

## Run a server

Lay the game out from its image, point the server at it, start it:

```console
$ sudo chandlery-unpack ghcr.io/danielbodart/chandlery/bedrock:1.26.52.3 \
      /var/lib/chandlery-packages/bedrock-1.26.52.3
$ sudo ln -sfn bedrock-1.26.52.3 /var/lib/chandlery-packages/wrlin
$ sudo systemctl enable --now chandlery@wrlin.socket chandlery@wrlin.service
$ chandlery-console wrlin list
```

`chandlery-unpack IMAGE[:TAG|@DIGEST] DEST` fetches, anonymously, only the
layers of the image that write the game (`/opt/<game>`) and its adapter
(`/usr/local`), checks each against its digest, and writes a package:

```
DEST/opt/<game>/                  the game, as the image has it
DEST/bin/<game>-server            the image's run script
DEST/lib/chandlery/prepare|stop|health
DEST/lib/chandlery/game.env       the image's ENV, the game's ready line, its CMD's arguments
DEST/libexec/chandlery/           the image's console.sh and health probe
```

Pin by digest (`…/bedrock@sha256:…`) to install exactly what you tested; a tag
works too. Each version goes in its own directory, never over an existing one.

**Upgrading** is the same, then repoint the link and restart. The world in
`/var/lib/chandlery/<name>` is untouched, and going back is repointing the link
back:

```console
$ sudo chandlery-unpack ghcr.io/danielbodart/chandlery/bedrock:1.26.60.1 \
      /var/lib/chandlery-packages/bedrock-1.26.60.1
$ sudo ln -sfn bedrock-1.26.60.1 /var/lib/chandlery-packages/wrlin
$ sudo systemctl restart chandlery@wrlin
```

### Per game

| Game | Host needs | Ports | Settings in `/etc/chandlery/<name>.env` |
|---|---|---|---|
| Bedrock | nothing more (BDS is built for glibc) | 19132/udp, 19133/udp | `CHANDLERY_SET=server-port=19134 server-portv6=19135` rewrites just those keys in `/data/server.properties`; everything else there is yours. |
| Hytale | a Java 25 as `java` on systemd's `PATH` (`/usr/bin`; or set `PATH=` in the env file). The image uses Temurin 25 | 5520/udp | `CHANDLERY_ARGS=--bind 0.0.0.0:5521`; `TREESINGER_SOCKET=/run/treesinger/treesinger.sock` to mint its session from a [Treesinger](https://github.com/danielbodart/treesinger) broker (and the drop-in below) |
| Valheim | `libatomic1` and `libpulse0` (Debian's names), as Iron Gate's image installs | 2456/udp, 2457/udp (always the game's port plus one) | `VALHEIM_PASSWORD=…`; `CHANDLERY_ARGS=-name Harbour -world Longship -port 2456 -public 1` replaces the image's default arguments, as compose's `command:` replaces its `CMD` |

`CHANDLERY_ARGS` is split on spaces. For an argument with a space in it,
override `ExecStart=` in a drop-in instead.

The file is read by systemd, so keep secrets in it mode `0600`, owned by root.
Valheim's password still ends up on the game's command line, the only place the
game takes one, as it does in the image.

Several servers of one game on one host each need their own ports: natively
there is no host-side remap. Open them in your firewall yourself.

### Running as another user, or with a world elsewhere

`systemctl edit chandlery@<name>` and `systemctl edit chandlery@<name>.socket`:

```ini
# chandlery@eldermarch.service.d/override.conf
[Service]
User=dan
Group=users
# A world that already lives somewhere else, instead of /var/lib/chandlery/<name>
# (the empty line clears the template's list, which is then restated):
BindPaths=
BindPaths=/data/servers/hytale-eldermarch:/data /run/chandlery/%i /run/chandlery/%i/private/opt:/opt
# Treesinger's socket, and the group that may use it:
SupplementaryGroups=treesinger
BindReadOnlyPaths=-/run/treesinger
# Hytale keys its auth store off /etc/machine-id: give each server its own.
BindReadOnlyPaths=/data/servers/hytale-eldermarch/machine-id:/etc/machine-id
```

```ini
# chandlery@eldermarch.socket.d/override.conf
[Socket]
SocketUser=dan
SocketGroup=users
```

## How it is confined

The template runs the game with `PrivateUsers=`, `PrivatePIDs=`,
`ProtectSystem=strict`, `ProtectHome=`, `ProtectProc=invisible`, no
capabilities, `NoNewPrivileges=` and `SystemCallFilter=@system-service`.
`systemd-analyze security chandlery@<name>` puts it at 1.4 (systemd 260). Every other
server's world under `/var/lib/chandlery` is hidden (a `TemporaryFileSystem=`),
as are `/srv`, `/mnt` and `/media`. The rest of the filesystem is read-only, not
invisible: the NixOS module goes further and shows the game nothing but its own
closure and world. If you keep worlds elsewhere, add that place to
`InaccessiblePaths=` in a drop-in.

Inside, the game sees what its container saw: its world at `/data`, the game at
`/opt/<game>` (staged on a private tmpfs at each start, writable for Bedrock as
its image layer was), `HOME=/data`. That is why the image's own scripts run
unchanged. Docker and systemd share one adapter.

## NixOS

The flake has the games as packages, built from the same pins CI writes to
`nix/versions.json` each time it publishes an image, and a module:

```nix
{
  inputs.chandlery.url = "github:danielbodart/chandlery";
  outputs = { nixpkgs, chandlery, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      modules = [
        chandlery.nixosModules.default
        {
          nixpkgs.config.allowUnfreePredicate = p: builtins.elem (nixpkgs.lib.getName p) [ "chandlery-bedrock" ];
          services.chandlery.servers.wrlin = {
            game = "bedrock";
            openFirewall = true;
          };
        }
      ];
    };
  };
}
```

`services.chandlery.servers.<name>` takes `game`, `package`/`packagePath` (a
Nix profile, to upgrade without a rebuild), `dataDir`, `user`/`group`, `port`
(and Bedrock's `portv6`), `extraArgs`, `environment`/`environmentFiles`,
`machineIdFile`, `treesinger.socket`, `readyPattern`, `notify` (join and leave
messages through Apprise) and `confine`. [docs/nix.md](../docs/nix.md) is the
design, with every option and what each test proves.
