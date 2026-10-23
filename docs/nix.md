# Chandlery on systemd, and as a Nix flake — design

The Docker images stay exactly as they are. Alongside them, each game gains a
**systemd-native** way to run: a unit per server, confined to its own world, with
the same lifecycle the images give Docker — a console you can type at, a stop
that saves before it exits, readiness that means the game is actually up. The
Nix flake (packages, a NixOS module, VM tests) is the first and best-tested
consumer of that, but nothing in the unit design needs Nix: plain-systemd
template units come out of the same pieces.

Bedrock is first and gets the most care; Hytale second (with Treesinger);
Valheim last.

## The idea in one paragraph

Inside its confinement, a native server sees **the same filesystem a container
sees**: its world at `/data`, the game at `/opt/<game>`, its console at a FIFO.
So the per-game scripts in `images/<game>/` — `prepare`, `run`, `stop-hook` —
run natively *unchanged*, and Docker and systemd share their behaviour by
construction rather than by copying it. What differs is only what Docker did
for us and systemd now does: tini/entrypoint become a socket unit (the FIFO),
`ExecStop` (the stop hook) and `Type=notify` (readiness); the image's layers
become a Nix package (or an unpacked directory on plain systemd); the bind
mount becomes `BindPaths=`.

## File layout

```
flake.nix, flake.lock         packages, overlay, module, checks, devShell
nix/
  versions.json               the pin: what each package builds, bumped by CI
  update-versions             sh+jq: rewrites one game's entry (CI and humans)
  oci.nix                     fetch layers from GHCR by digest, unpack a subtree
  pkgs/
    bedrock.nix               Mojang zip -> autoPatchelf'd package
    hytale.nix                GHCR layers -> package, with temurin-jre-bin-25
    valheim.nix               GHCR layers -> autoPatchelf'd package
    mc-monitor.nix            Bedrock's health probe (itzg/mc-monitor, pinned)
    chandlery-a2s.nix         Valheim's health probe (images/valheim/probe)
    chandlery-systemd.nix     the native tools below, as one package
  module.nix                  services.chandlery
  tests/
    fake-game.nix             a game-shaped package around test/fixtures' fakes
    module.nix                VM: the unit mechanics on a fake (fast, no download)
    bedrock.nix               VM: real BDS end to end
    hytale.nix                VM: hytale adapter on fake java + fake Treesinger
    valheim.nix               VM: valheim adapter on test/fixtures/fake-valheim
    template.nix              VM: the plain-systemd template units, no module
systemd/
  go.mod                      github.com/danielbodart/chandlery/systemd (no deps)
  cmd/chandlery-ready/        Type=notify wrapper (Go, with tests)
  cmd/chandlery-notify/       journal follower -> apprise (Go, with tests)
  bin/chandlery-console       chandlery-console <n> [cmd...]
  bin/chandlery-stop          ExecStop: run the package's stop hook, wait for exit
  bin/chandlery-prepare       ExecStartPre: stage /opt, run package prepare, set keys
  bin/chandlery-set-property  key=value into a .properties file, nothing else touched
  bin/chandlery-unpack        OCI layers -> a package dir (Nix builder and humans)
  units/chandlery@.service    plain-systemd templates
  units/chandlery@.socket
  README.md                   running Chandlery on plain systemd
docs/nix.md                   this file
```

Go is used for the two long-running helpers because both have to be correct
under signals and back-pressure, which `sh` makes hard (see below); the repo
already builds Go (`images/valheim/probe`, the fixtures). Everything else is
POSIX `sh` in the style of `images/`.

## The package layout

A Chandlery package — the Nix store path, or a directory `chandlery-unpack`
lays out on plain systemd — is the image's filesystem minus Debian:

```
<pkg>/opt/<game>/                 the game, exactly the tree the image bakes at /opt/<game>
<pkg>/bin/<game>-server           images/<game>/run          (image: /usr/local/bin/<game>-server)
<pkg>/bin/chandlery-server        -> <game>-server           (one name for generic units)
<pkg>/lib/chandlery/prepare       images/<game>/prepare      (image: /usr/local/lib/chandlery/prepare)
<pkg>/lib/chandlery/stop          images/{bedrock,hytale}/stop-hook; absent for Valheim (see Stop)
<pkg>/lib/chandlery/health        images/{bedrock,valheim}/health, if the game has one
<pkg>/lib/chandlery/game.env      GAME=, <GAME>_VERSION=, CHANDLERY_READY=, CHANDLERY_STAGE=
```

In the Nix packages, `bin/` and `lib/chandlery/` are `makeWrapper`s around the
scripts from this repository's `images/<game>/`: they set the version variables
the image sets with `ENV` (`BEDROCK_VERSION`, `HYTALE_VERSION`,
`HYTALE_DISABLE_UPDATES=1`, `VALHEIM_*`) and a `PATH` with what the image had
installed (`coreutils`, `findutils`, `curl` and the JRE for Hytale, `mc-monitor`
for Bedrock's health, `chandlery-a2s` for Valheim's). Everything
version-specific lives in the package, so pointing a profile at a new package
changes the game, its scripts and its readiness line together, and the unit
file not at all — which is what lets Tidewaiter swap versions without a
`nixos-rebuild`.

`game.env` lets one generic unit run any game: `CHANDLERY_READY` is the
readiness regex, `CHANDLERY_STAGE` is `copy-links` for a game that writes into
its own directory (Bedrock) and `link` for one that does not.

## Inside the confinement

| Path in the unit | Source | Mode |
|---|---|---|
| `/data` | `dataDir` | rw — the only writable game state |
| `/opt` | `/run/chandlery/<n>/private/opt` (staged by `chandlery-prepare`) | rw tmpfs |
| `/run/chandlery/<n>` | itself: `console` (FIFO) and `private/` | rw |
| `/etc/machine-id` | `machineIdFile`, when set | ro |
| `/run/treesinger` | itself, when `treesinger.socket` is set, `-`optional | ro |
| `/etc/{resolv.conf,hosts,nsswitch.conf,localtime}`, `/etc/ssl/certs/ca-certificates.crt` | host / `cacert` | ro |
| `/nix/store/...` | the unit's closure (`confinement.mode = "full-apivfs"`) | ro |
| `/proc`, `/sys`, `/dev`, `/tmp` | API VFS, `PrivateTmp`, `PrivateDevices` | — |

Nothing else of `/data`, `/home` or the host is mounted. `HOME=/data` and
`WorkingDirectory=/data`, as in the image.

**Staging `/opt`.** BDS writes into its own directory (the image gives it a
writable layer) and `images/bedrock/prepare` replaces four entries there with
links to `/data`. The store is read-only, so `chandlery-prepare` builds
`/opt/bedrock` as a tree of real directories and symlinks into the package
(`cp -rs`) on a tmpfs — the native equivalent of the container's writable
layer, thrown away on stop like one — and then runs the unchanged `prepare`.
Hytale and Valheim only read their game dir, so for them `/opt/<game>` is a
single symlink to the package. (`images/bedrock/prepare` gained one
`chmod u+w` on the files it seeds, because a copy of a read-only store file is
read-only: the one refactor this design needed in `images/`. In the image it
changes nothing; `make test-base test-bedrock` pass.)

## The units

For a server `<n>` (the NixOS module renders exactly this; `systemd/units` are
the same directives as templates):

### `chandlery-<n>.socket`

```ini
[Socket]
ListenFIFO=/run/chandlery/<n>/console
SocketUser=<user>
SocketGroup=<group>
SocketMode=0600
DirectoryMode=0755
RemoveOnStop=yes
```

systemd holds the FIFO open for the service's whole life, so the game never
reads EOF when a writer closes — the job the entrypoint's `exec 3<>` did. Mode
`0600`: the server's user (and root) can type at it; a shared group like
`users` cannot.

### `chandlery-<n>.service`

```ini
[Unit]
Requires=chandlery-<n>.socket
After=chandlery-<n>.socket network-online.target
Wants=network-online.target
RequiresMountsFor=<dataDir>

[Service]
Type=notify
NotifyAccess=all
Sockets=chandlery-<n>.socket
StandardInput=socket
StandardOutput=journal
StandardError=journal
User=<user>
Group=<group>
UMask=0022
Environment=HOME=/data CHANDLERY_CONSOLE=/run/chandlery/<n>/console …environment
EnvironmentFile=…environmentFiles
WorkingDirectory=/data
RuntimeDirectory=chandlery/<n>/private
RuntimeDirectoryMode=0700
ExecStartPre=+chandlery-make-data-dir <dataDir> <user> <group>
ExecStartPre=chandlery-prepare <packagePath> [--set server-port=<port> --set server-portv6=<portv6>]
ExecStart=chandlery-ready -- <packagePath>/bin/<game>-server <game args> <extraArgs>
ExecStop=chandlery-stop <packagePath>
KillSignal=SIGINT
TimeoutStartSec=15min
TimeoutStopSec=5min
Restart=on-failure
RestartSec=10s
# confinement + hardening: see Hardening
```

`chandlery-make-data-dir` (`+`, so as root and before the sandbox needs the bind
source) creates `dataDir` owned by the server's user **only if it is missing**,
and never touches an existing one — Dan's are already `dan:users`, and a
`tmpfiles` `d` line would re-own and re-mode them.

### Readiness: `chandlery-ready`

`Type=notify` through a small init-like wrapper:

```
chandlery-ready [--pattern REGEX] -- COMMAND [ARGS…]
```

- Starts `COMMAND` as its child with **stdin inherited** (the FIFO) and stdout
  and stderr on a pipe; copies every line to its own stdout (the journal)
  unchanged.
- On the first line matching the pattern (RE2; default `CHANDLERY_READY` from
  the package's `game.env`) sends `READY=1` to `$NOTIFY_SOCKET` itself (a unix
  datagram — no `systemd-notify` fork, no dependency on systemd's binaries).
  Without `NOTIFY_SOCKET` it is a transparent pass-through, so it also works in
  a shell.
- Ignores `SIGINT`/`SIGTERM` itself and keeps draining until the child exits:
  `KillMode=control-group` delivers `KillSignal` to the game directly, and the
  wrapper must not die before the game's last lines ("Quit correctly") reach
  the journal.
- Reaps orphans and exits with the child's status (`128+n` for a signal).
- Holds an exclusive `flock` on `/run/chandlery/<n>/private/running` until the
  child has exited and the pipe is drained — what `chandlery-stop` waits on.

Why not exec the game and leave a reader behind: with `PrivatePIDs=yes` the
main process is PID 1 of its namespace, and when PID 1 exits the kernel kills
everything else in it — a reader child would be killed with the game's final
output still in the pipe. Keeping the wrapper as PID 1 also gives the game a
parent that reaps.

Default patterns (overridable per server; they are the riskiest guess in this
design, because a pattern that never matches means a healthy server killed at
`TimeoutStartSec` — see Open questions):

| Game | `CHANDLERY_READY` |
|---|---|
| Bedrock | `Server started\.` |
| Hytale | to be taken from a live server's log (eldermarch) before Hytale ships |
| Valheim | `Game server connected` (to confirm against a live log) |

`readyPattern = null` renders `Type=exec` and no pattern: for a game or mod
whose boot line is unknown.

### Stop: `chandlery-stop`

```
chandlery-stop PACKAGE_PATH
```

1. If `PACKAGE_PATH/lib/chandlery/stop` exists, run it — the image's own stop
   hook, verbatim (`chandlery-console stop`, `chandlery-console /stop`) — with
   `chandlery-console` on `PATH` and `CHANDLERY_CONSOLE` pointing at the FIFO.
2. Wait for `flock /run/chandlery/<n>/private/running`, i.e. until the game has
   exited and its output is in the journal.

systemd then sends `KillSignal=SIGINT` to anything left (normally nothing) and
`SIGKILL` only when `TimeoutStopSec=5min` runs out — the same bounds Docker's
`stop_grace_period: 5m` gave. If the hook fails, systemd proceeds to
`KillSignal`, as the entrypoint fell back to `SIGTERM`.

**Valheim diverges**: its stop hook is `kill -INT "$1"` on the server's PID.
With `PrivatePIDs=yes` each `Exec*` command lives in its own PID namespace, so
`ExecStop` cannot name the game. Instead the package ships no `stop` and
`KillSignal=SIGINT` — the signal Valheim saves on — does the job natively.
`SIGINT` is a sound `KillSignal` for all three: after a console stop nothing is
left to receive it, and Java treats it as it treats `SIGTERM`.

### The console: `chandlery-console`

```
chandlery-console <n> <command> [args…]    type one line at server <n>
chandlery-console <n>                      interactive: follow its journal, send each line you type
```

The one-shot form sets `CHANDLERY_CONSOLE=/run/chandlery/<n>/console` and runs
the image's `console.sh` logic (line-oriented write, refusing with 69 when
there is no FIFO). The interactive form is the native `docker attach`:
`journalctl -fu chandlery-<n>` alongside a line reader into the FIFO; Ctrl-C
leaves, and the server keeps running.

### Join/leave notifications: `chandlery-<n>-notify.service`

Replaces loggifly. A separate unit per server, so a slow or failing Apprise can
never back-pressure the game's stdout:

```
chandlery-notify --config FILE
```

`FILE` is JSON: `{ "unit": "chandlery-<n>.service", "title": "…", "rules":
[ { "regex": "…", "message": "…" } ] }`. It runs `journalctl -f -n0 -o cat
-u <unit>` (following across restarts), matches each line against each rule in
order (RE2, which accepts loggifly's Python `(?P<name>…)` groups), renders
`message` by substituting `{{ name }}` with each named group — loggifly's own
template syntax, so the compose labels carry over verbatim — and runs
`apprise -t TITLE -b BODY`. The URL never touches argv: it is
`LoadCredential=apprise-url:<appriseUrlFile>`, read into `APPRISE_URLS` for the
child. The unit is `DynamicUser=yes`, `SupplementaryGroups=systemd-journal`,
otherwise hardened like the game.

Default rules, from the loggifly labels in nix-config's compose files:

| Game | Regex | Message |
|---|---|---|
| Bedrock | `Player connected: (?P<player>.+?), xuid:` | `🟢 {{ player }} joined` |
| Bedrock | `Player disconnected: (?P<player>.+?), xuid:` | `🔴 {{ player }} left` |
| Hytale | `Player '(?P<player>[^']+)' joined world` | `🟢 {{ player }} joined` |
| Hytale | `\[Universe\|P\] Removing player '(?P<player>[^']+)'` | `🔴 {{ player }} left` |
| Valheim | none yet (no Valheim was ever behind loggifly) | |

## Hardening

On the game unit, each line checked by `systemd-analyze security` in the VM
tests (the test asserts an exposure ceiling so a regression fails CI):

```ini
# NixOS confinement: RootDirectory + TemporaryFileSystem=/ + the closure, full-apivfs
PrivateUsers=yes            # see Open questions for treesinger's supplementary group
PrivatePIDs=yes             # systemd >= 257; dropped with a warning on older
ProtectProc=invisible
ProcSubset=pid              # if the games tolerate it (Java reads /proc/cpuinfo …)
NoNewPrivileges=yes
CapabilityBoundingSet=
AmbientCapabilities=
SystemCallFilter=@system-service
SystemCallArchitectures=native
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
PrivateTmp=yes
PrivateDevices=yes
PrivateIPC=yes
RemoveIPC=yes
ProtectHostname=yes
ProtectClock=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectSystem=strict
ProtectHome=yes
```

Not set: `MemoryDenyWriteExecute` (Java's JIT and Valheim's Mono need W+X),
`PrivateNetwork` (they are servers), `IPAddressDeny` (players are anywhere).
`confine = false` on a server drops confinement (not the rest) as an escape
hatch.

**Profiles and the closure.** Confinement mounts the closure of the unit's own
strings. With the default `packagePath = "${package}"` that closure contains
the game. When `packagePath` is a profile Tidewaiter repoints at runtime, the
next package is not in the unit's closure, so the module also binds
`/nix/store` and `/nix/var/nix/profiles` read-only. Every other world, `/data`,
`/home` and `/etc` stay invisible; what is lost is only "nothing of the store
but my closure", and the store is world-readable on the host anyway.

## Nix flake outputs

| Output | What |
|---|---|
| `packages.x86_64-linux.bedrock` | BDS from Mojang's zip (`fetchurl`, sha256 from `versions.json`, `-A chandlery/bedrock` as the image's fetch does), unzipped, the same two build leftovers dropped as `images/bedrock/fetch`, `autoPatchelfHook` for glibc/libstdc++ (and whatever else `autoPatchelf` reports). `meta.license = unfree`. |
| `packages.x86_64-linux.hytale` | `/opt/hytale` unpacked from the published GHCR image's layers (below), run with `temurin-jre-bin-25` — 25.0.3, the JRE the image pins. Nothing is fetched from Hytale. |
| `packages.x86_64-linux.valheim` | `/opt/valheim` the same way, `autoPatchelf`'d (`libatomic`, `libpulseaudio`, `zlib`, `stdenv.cc.cc.lib`), `chandlery-a2s` for health. |
| `packages.<sys>.chandlery-systemd` | the native tools (`systemd/`) — any Linux. |
| `packages.<sys>.default` | `chandlery-systemd`. |
| `overlays.default` | `pkgs.chandlery.{bedrock,hytale,valheim,systemd}` built with the consumer's `pkgs`. |
| `nixosModules.default` / `.chandlery` | `services.chandlery`. |
| `checks.x86_64-linux.*` | the packages, `go test` for `systemd/` and the probe, the VM tests. |
| `devShells.<sys>.default` | go, jq, curl, shellcheck, gnumake. |

Systems: the games are x86_64-only (BDS, Valheim and the published images have
no ARM builds); the tools and module evaluate everywhere.

The module builds its default packages with the system's own `pkgs`
(`pkgs.callPackage`), so the consumer's `allowUnfree` decides, and nothing pulls
in the flake's nixpkgs. The flake's own `packages` set an
`allowUnfreePredicate` for exactly these three names, so `nix build .#bedrock`
works without `--impure`.

### Packages from GHCR layers, by digest

Hytale's files are OAuth-gated and Valheim's need a licensed Steam account; the
images have already done both. So the Nix packages take the game from the
published image, **one `fetchurl` per layer**:

- `versions.json` records the image's manifest `digest` (provenance — it names
  exactly the image the package came from) and the ordered list of the layer
  digests that write under `/opt/<game>` (found from the image config's
  `history`, whose non-empty entries pair with the layers in order; for Hytale
  0.7.4 that is 33 of 44 layers: the 32 asset buckets and the `Server/` layer —
  no Debian, no JRE).
- Each layer is `fetchurl { url = "https://ghcr.io/v2/<repo>/blobs/<digest>";
  sha256 = <the digest's hex>; curlOptsList = [ "-H" "Authorization: Bearer QQ==" ]; }`.
  GHCR serves public images to that anonymous bearer (checked: manifests and
  blobs of all three images, following the redirect to
  `pkg-containers.githubusercontent.com`). The **OCI digest is the Nix hash**:
  there is no second hash to compute or keep in sync, and CI needs no Nix to
  bump a version.
- The layers are named by digest, so **an unchanged bucket is the same store
  path across versions** and is not downloaded again — the image's
  layer-by-churn dedupe carries straight over into the Nix store.
- An ordinary (not fixed-output) derivation runs `chandlery-unpack --blobs` over
  them in order: gunzip (or zstd), extract only `opt/<game>/`, honour `.wh.`
  whiteouts, refuse absolute paths and `..`. Ownership and mtimes fall away in
  the store, which is what the image normalised them for anyway.

`chandlery-unpack` is the same script a plain-systemd user runs to install a
package from GHCR (`chandlery-unpack ghcr.io/danielbodart/chandlery/bedrock:<tag>
/opt/chandlery/bedrock-<tag>`), so the one unpacker is exercised by both.

Bedrock comes from Mojang's zip rather than the image because the zip is public
and its sha256 is already what the image's build verifies: the Nix package and
the image are pinned by the same number.

### `nix/versions.json`

```json
{
  "bedrock": { "version": "1.26.52.3", "sha256": "<hex of the zip>" },
  "hytale": {
    "version": "0.7.4",
    "image": "ghcr.io/danielbodart/chandlery/hytale",
    "digest": "sha256:193abd…",
    "revision": "<repo sha the image was built from>",
    "layers": [ "sha256:…", "…" ]
  },
  "valheim": {
    "version": "0.221.12", "buildId": "…", "manifestGid": "…",
    "image": "ghcr.io/danielbodart/chandlery/valheim",
    "digest": "sha256:…", "revision": "…", "layers": [ "…" ]
  }
}
```

`nix/update-versions` rewrites one entry with `jq`, keeping the file's key
order and two-space indent so diffs stay one hunk per game:

```
nix/update-versions bedrock <version> <sha256>
nix/update-versions oci hytale|valheim <image>@<digest> <version> [key=value…]
```

The `oci` form fetches the manifest and config anonymously and derives
`layers` itself. It leaves the file **unchanged** when only `digest`/`revision`
moved but the version and `/opt` layers did not (a code-only image rebuild): the
package would be byte-identical, and a new store path would make Tidewaiter
restart a server for nothing.

### CI

Each game's workflow gains a final step in the run that published the image,
after `docker push`:

- **bedrock.yml**: `nix/update-versions bedrock "$VERSION" "$SHA256"` — the
  sha256 it already computed for the build-arg.
- **hytale.yml / valheim.yml**: the pushed digest from `docker inspect
  --format '{{index .RepoDigests 0}}'`, then `nix/update-versions oci …`.

then commits as `<game>: <version> in nix/versions.json` and pushes to
`master`, looping on a lost race: `fetch`, `reset --hard origin/master`, re-run
`update-versions`, commit, `push` — three workflows can finish together, and
re-applying is cheaper and safer than merging JSON. Needs `contents: write` on
those jobs. A push made with `GITHUB_TOKEN` starts no workflow, so this cannot
loop.

`ci.yml` gains a `nix` job (`DeterminateSystems/nix-installer-action`, KVM is
available on `ubuntu-latest`): `nix flake check`, which builds the packages and
runs the VM tests. The Hytale/Valheim checks that need their 1.8 GB/1 GB of
layers are a separate, non-blocking job (disk on the free runner is the
constraint — see Open questions); the fake-game VM tests always run.

## NixOS module: `services.chandlery`

```nix
services.chandlery.servers.<name> = {
  enable          = true;                              # bool, default true
  game            = "bedrock";                         # enum [ "bedrock" "hytale" "valheim" ]
  package         = pkgs.chandlery.bedrock;            # package; default pkgs.callPackage of nix/pkgs/<game>.nix
  packagePath     = "${package}";                      # str; what ExecStart(Pre)/ExecStop use
  dataDir         = "/var/lib/chandlery/<name>";       # str
  user            = "chandlery";                       # str; the module creates user+group "chandlery" only if used
  group           = "chandlery";                       # str
  port            = 19132;                             # port; default 19132 / 5520 / 2456 by game
  portv6          = 19133;                             # port; Bedrock only; default port + 1
  ports           = [ "19132/udp" "19133/udp" ];       # read-only: what it listens on, for portical/tidewaiter/firewall
  openFirewall    = false;                             # bool: open `ports` in networking.firewall
  extraArgs       = [ ];                               # listOf str, appended verbatim (Valheim default below)
  environment     = { TZ = "Europe/London"; };         # attrsOf str
  environmentFiles = [ ];                              # listOf path, e.g. VALHEIM_PASSWORD from sops
  machineIdFile   = null;                              # null or str, bound read-only at /etc/machine-id
  readyPattern    = "Server started\\.";               # null or str (RE2); default the package's
  stopTimeout     = "5min";                            # str: TimeoutStopSec
  confine         = true;                              # bool: confinement (the escape hatch)
  treesinger.socket = null;                            # null or str; Hytale only (assertion)
  notify = {
    enable         = false;                            # bool
    appriseUrlFile = null;                             # null or str: file holding the Apprise URL (a sops secret)
    title          = "<name>";                         # str
    rules          = [ { regex = "…"; message = "…"; } ];  # default per game, as in the table above
  };
};
```

Also: `services.chandlery.tools` (package, default `pkgs.chandlery.systemd`,
added to `environment.systemPackages` for `chandlery-console`).

### Ports, without clobbering the operator's config

| Game | How `port` reaches the game | What the operator's file keeps |
|---|---|---|
| Bedrock | `chandlery-prepare --set server-port=… --set server-portv6=…` rewrites exactly those two keys in `/data/server.properties` after `prepare` seeds it; appends a key that is missing; leaves every other line, comment and order alone. | Everything else. The two keys are owned by the module, which is honest: the file on disk says what the server binds. |
| Hytale | `--bind 0.0.0.0:<port>` on the command line (the flag `images/hytale/run` already passes through). `/data/config.json` is not touched. | All of `config.json`. |
| Valheim | `-port <port>` on the command line; it has no config file. The query port is `port + 1`, as Valheim insists. | — |

Several servers of one game on one host need distinct ports, which natively
means distinct *server* ports (there is no host-side remap): Dan's four Hytale
servers become `port = 5520 … 5523`. Bedrock's `portv6` defaults to `port + 1`,
so two Bedrock servers want ports two apart (19132/19133, 19134/19135).

`extraArgs` default: `[ ]` for Bedrock and Hytale; for Valheim the image's
`CMD`, `[ "-name" "<name>" "-world" "Dedicated" "-public" "1" ]`. The module
always adds the port flag; `run` always adds its own non-negotiables.

### How each shared contract is met

**Units.** `chandlery-<n>.service`, `User=`/`Group=` from `user`/`group`
(Dan: `dan`/`users`), state in `dataDir`, confined with only the closure and
`dataDir` visible; `chandlery-<n>.socket` owns `/run/chandlery/<n>/console`
(`ListenFIFO`, `StandardInput=socket`); `ExecStop` types the save-and-quit and
waits (`TimeoutStopSec=5min`); `chandlery-console <n> <cmd…>`; `Type=notify`
via `chandlery-ready`.

**`package` / `packagePath`.** Exactly as specified. Every `Exec*` line goes
through `packagePath`, so a profile at `/nix/var/nix/profiles/chandlery/<n>`
moves the whole game. The module leaves `restartIfChanged` at its default; it
is Tidewaiter's module that sets it false for a unit it manages.

**Treesinger** (as Treesinger's own design, `docs/systemd.md` on its `systemd`
branch, asks):

- `images/hytale/run` learns `TREESINGER_SOCKET`: when set, the same POST it
  makes to `TREESINGER_URL` goes over `curl --unix-socket "$TREESINGER_SOCKET"
  http://treesinger/v1/session`. Same extraction, same warn-and-boot-
  unauthenticated on any failure, tokens exported into the server's own
  `HYTALE_SERVER_SESSION_TOKEN` / `_IDENTITY_TOKEN`, never on argv. Docker's
  `TREESINGER_URL` path is unchanged.
- **Divergence from the contract's wording**: the mint happens *inside*
  `ExecStart` (in `run`, before it `exec`s Java), not in an `ExecStartPre`. An
  `ExecStartPre` cannot set the environment `ExecStart` sees — systemd reads
  `EnvironmentFile=` before the first command — and a session env file would
  put the tokens on disk. Minting in `run` keeps Docker and systemd on the one
  code path. Treesinger's design reached the same conclusion.
- The unit gets `SupplementaryGroups=treesinger`, `BindReadOnlyPaths=-/run/treesinger`
  (the directory, not the socket: a bind of the socket file pins an inode that
  goes stale when the broker restarts; `connect()` works through a read-only
  bind; `-` keeps the game booting unauthenticated if the broker is absent),
  `Environment=TREESINGER_SOCKET=<socket>`, and `wants`/`after`
  `treesinger.service`.

**Portical.** Not a dependency. Chandlery exposes `ports`; to forward them:

```nix
systemd.services.chandlery-wrlin.portical.forward = [ "19133:19132/udp" ];
```

**Tidewaiter.** Not a dependency. A server opts in from the deployer's side:

```nix
services.chandlery.servers.wrlin.packagePath = "/nix/var/nix/profiles/chandlery/wrlin";
systemd.services.chandlery-wrlin.tidewaiter = {
  desired = config.services.chandlery.servers.wrlin.package;
  profile = "/nix/var/nix/profiles/chandlery/wrlin";
  ports   = config.services.chandlery.servers.wrlin.ports;
  detector = "conntrack";
  health  = [ "port-bound" "uptime" ];
};
```

Chandlery's part of that bargain: everything version-specific comes from the
profile (above), the unit is ready only when the game says so (so Tidewaiter's
"restart, then health-check" starts from a server that is genuinely up), and a
stop saves the world (so Tidewaiter's restart for an update or rollback loses
nothing). The package's `lib/chandlery/health` is there for a future
`health = [ "command" ]`.

### Dan's servers, as they would read

```nix
services.chandlery.servers.wrlin = {
  game = "bedrock";
  user = "dan"; group = "users";
  dataDir = "/data/servers/wrlin_survival/serverfiles";
  notify = { enable = true; title = "WRLIN Survival";
             appriseUrlFile = config.sops.secrets.discord-webhook.path; };
};
services.chandlery.servers.hytale-eldermarch = {
  game = "hytale";
  user = "dan"; group = "users";
  dataDir = "/data/servers/hytale-eldermarch";
  port = 5520;
  machineIdFile = "/data/servers/hytale-eldermarch/machine-id";
  treesinger.socket = "/run/treesinger/treesinger.sock";
  environment.TZ = "Europe/London";
  notify = { enable = true; title = "Hytale Eldermarch";
             appriseUrlFile = config.sops.secrets.discord-webhook.path; };
};
```

## Plain systemd (no Nix)

`systemd/units/chandlery@.{service,socket}` carry the same directives, with
`%i` for `<n>` and fixed conventions where systemd cannot expand variables in
paths: the package at `/opt/chandlery/%i` (a symlink, i.e. a profile by another
name — repoint it to upgrade), state in `StateDirectory=chandlery/%i`
(`/var/lib/chandlery/%i`), user `chandlery`. Per-server settings go in a
drop-in (`systemctl edit chandlery@wrlin`): `User=`, `Environment=
CHANDLERY_ARGS=…`, `Environment=CHANDLERY_SET=server-port=19134 …`. Instead of
the Nix closure, the template mounts `/usr`, `/etc/ssl`, the package and its
own state, with `TemporaryFileSystem=` over `/var/lib/chandlery`, `/srv`,
`/home` and `/mnt` so no other world is visible. `make install-systemd
PREFIX=/usr/local` installs the tools and templates; `systemd/README.md`
documents the three-command setup (install, `chandlery-unpack`, `systemctl
enable --now chandlery@<n>.socket chandlery@<n>.service`). Hytale wants a Java
25 on the host and Valheim `libatomic1 libpulse0`, as the images install. A VM
test runs the templates without the module, on the fake game.

## Test plan

Existing tests stay as they are and stay green (`make test`: base 12, bedrock
14, hytale 13, valheim 11 `it` cases; after this design's one refactor, `make
test-base test-bedrock` ran 10 + 13 with 0 failures, the rest host-skipped). New:

**Go (`go test`, in `checks`)** — `chandlery-ready`: passes lines through
byte-for-byte, notifies once and only on a match, works without
`NOTIFY_SOCKET`, keeps draining after `SIGINT`/`SIGTERM`, exits with the child's
status, holds the lock until drained. `chandlery-notify`: loggifly's regexes
(copied from nix-config) against real BDS/Hytale log lines, template rendering,
no URL on argv.

**Shell (in `checks`, no VM)** — `chandlery-set-property` (replace, append,
comments and order kept, `key=` prefixes not confused, e.g. `server-port` vs
`server-portv6`); `chandlery-unpack` on a synthetic layer set (order,
whiteouts, path traversal refused); `nix/update-versions` on a fixture file.

**`nix/tests/module.nix` (fake game, fast, every push)** — a package built
around `test/fixtures/fake-server` (ignores `SIGTERM`, saves only on `stop`):
socket and FIFO exist with the right owner and mode; the unit stays
`activating` until the ready line and goes `active` on it; `chandlery-console`
reaches the game; `systemctl stop` saves (the fake's "world saved" in the
journal, then exit 0, no `SIGKILL`); a crash restarts it; confinement — a
second server's `dataDir` and `/home` are absent inside, `/data` is the
server's own, `/etc/machine-id` is the per-server file; `PrivatePIDs` hides
host processes; `systemd-analyze security` exposure under a ceiling; profile
mode — `packagePath` at a profile, repoint, restart, new version running;
notify — a `json://` Apprise URL at a tiny listener in the VM receives `🟢 Steve
joined` for a matching line and nothing for others, with the URL absent from
`/proc/*/cmdline`.

**`nix/tests/bedrock.nix` (real BDS)** — starts; `READY` on `Server started.`;
`chandlery-console wrlin say hello` shows in the journal; a world is created
under `dataDir/worlds`; `server-port`/`server-portv6` patched, a hand-added key
in `server.properties` survives restarts; the RakNet probe
(`lib/chandlery/health`) answers on the patched port; `systemctl stop` logs
`Quit correctly` and exits cleanly within the timeout; a restart reuses the
world.

**`nix/tests/hytale.nix`** — the real adapter on fake `java` and a fake
Treesinger (a unix-socket HTTP server in the VM answering `/v1/session`):
tokens arrive in the environment and not on argv; broker absent → boots
unauthenticated with the warning; `--bind 0.0.0.0:<port>` present; the
supplementary group works under `PrivateUsers`. A gated `hytale-real` check
boots the real package to `READY` where disk allows.

**`nix/tests/valheim.nix`** — the adapter on `fake-valheim`: `-port`,
password from `environmentFiles` and absent from argv, stop by `SIGINT` saves.

**`nix/tests/template.nix`** — the plain-systemd templates with the fake game.

## Order of work

1. `systemd/` tools with their Go and shell tests.
2. `flake.nix`, `nix/versions.json` (seeded from the current releases),
   `nix/update-versions`, `nix/oci.nix`, `packages.bedrock`.
3. The module and `tests/module.nix`, then `tests/bedrock.nix`. **Bedrock done.**
4. `TREESINGER_SOCKET` in `images/hytale/run` (+ its Docker test),
   `packages.hytale`, `tests/hytale.nix`.
5. `packages.valheim`, `tests/valheim.nix`.
6. CI: versions bump in the three workflows, the `nix` job.
7. Plain-systemd templates, `make install-systemd`, `tests/template.nix`,
   `systemd/README.md`, a README section.

## Open questions

1. **Readiness lines for Hytale and Valheim** need confirming from live logs
   (Dan's eldermarch for Hytale). Until then their default could be `null`
   (`Type=exec`) rather than a guess that kills a healthy server at
   `TimeoutStartSec`. Proposed: ship Hytale/Valheim with `null` unless
   confirmed.
2. **`PrivateUsers=yes` and `SupplementaryGroups=treesinger`.** In a user
   namespace that maps only the unit's user and group, setting an unmapped
   supplementary group may fail or be dropped. If the VM test shows that,
   Hytale-with-Treesinger uses `PrivateUsers=identity` (systemd 257+, maps
   0–65535 to themselves, still no capabilities on the host).
3. **BDS and the symlinked `/opt/bedrock`.** If BDS resolves its own directory
   through `/proc/self/exe`, it would read the store's stock
   `server.properties`. The Bedrock VM test settles it; the fallback is to copy
   `bedrock_server` itself (≈ 100 MB) into the staged dir, moving the staging
   from `/run` (RAM) to a `CacheDirectory`.
4. **Type=notify inside confinement.** systemd bind-mounts the notify socket
   into a `RootDirectory=` namespace on current versions; confirmed by the
   module VM test, not assumed.
5. **Pushing to `master` from CI** assumes no branch protection that blocks
   `GITHUB_TOKEN`. If there is one, the bump becomes a PR that auto-merges.
6. **Getting a bump to Dan's server** needs nix-config's `chandlery` input to
   move. That is nix-config's call (e.g. `autoUpgrade` with
   `--update-input chandlery`, or a scheduled `nix flake update chandlery`
   commit); nothing here forces it.
7. **First boot under Tidewaiter.** A profile that does not exist yet means an
   `ExecStart` that fails. Tidewaiter's module should seed the profile with
   `desired` at activation when it is missing; noted for that branch.
8. **Disk on the free runner** for checks that unpack Hytale's 3.4 GB: gated
   off the blocking path; or the check frees runner disk first.
9. **Redistribution.** The packages contain what the images already
   redistribute (PLAN 7.3); a binary cache serving them would widen that.
   Proposed: no public cache; each host builds (fetches) its own.
10. **Valheim notifications.** No existing rule to reuse; `Got character ZDOID
    from (?P<player>\S+)` is the usual join line, leave is harder. Out of scope
    until a Valheim server runs here.
