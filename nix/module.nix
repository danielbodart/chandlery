# services.chandlery: each game server a confined native systemd service, with
# the lifecycle its Docker image gives it — a console FIFO, a stop that saves,
# readiness that means the game is up. docs/nix.md is the design.
{
  config,
  lib,
  pkgs,
  utils,
  ...
}:

let
  inherit (lib)
    types
    mkOption
    mkIf
    literalExpression
    ;
  inherit (utils) escapeSystemdExecArgs;

  cfg = config.services.chandlery;
  servers = lib.filterAttrs (_: s: s.enable) cfg.servers;

  # What differs between games. Everything else is one unit shape.
  games = {
    bedrock = {
      package = pkgs.callPackage ./pkgs/bedrock.nix { };
      packageText = "pkgs.callPackage (chandlery + \"/nix/pkgs/bedrock.nix\") { }";
      port = 19132;
      readyPattern = "Server started\\.";
      # BDS insists on an IPv6 socket too.
      ports = s: [
        {
          port = s.port;
          proto = "udp";
        }
        {
          port = s.portv6;
          proto = "udp";
        }
      ];
      # BDS takes its ports only from server.properties: set those two keys
      # and leave the rest of the operator's file alone.
      prepareArgs = s: [
        "--set"
        "server-port=${toString s.port}"
        "--set"
        "server-portv6=${toString s.portv6}"
      ];
      args = s: [ ];
      extraArgs = name: [ ];
      # loggifly's labels from the compose files, verbatim.
      rules = [
        {
          regex = "Player connected: (?P<player>.+?), xuid:";
          message = "🟢 {{ player }} joined";
        }
        {
          regex = "Player disconnected: (?P<player>.+?), xuid:";
          message = "🔴 {{ player }} left";
        }
      ];
    };
    hytale = {
      package = pkgs.callPackage ./pkgs/hytale.nix { };
      packageText = "pkgs.callPackage (chandlery + \"/nix/pkgs/hytale.nix\") { }";
      port = 5520;
      readyPattern = "Hytale Server Booted!";
      # QUIC.
      ports = s: [
        {
          port = s.port;
          proto = "udp";
        }
      ];
      prepareArgs = s: [ ];
      # The server's own flag, as compose's command: passed it; config.json is
      # left to the operator.
      args = s: [
        "--bind"
        "0.0.0.0:${toString s.port}"
      ];
      extraArgs = name: [ ];
      # loggifly's labels from the compose files, verbatim.
      rules = [
        {
          regex = "Player '(?P<player>[^']+)' joined world";
          message = "🟢 {{ player }} joined";
        }
        {
          regex = "\\[Universe\\|P\\] Removing player '(?P<player>[^']+)'";
          message = "🔴 {{ player }} left";
        }
      ];
    };
    valheim = {
      package = pkgs.callPackage ./pkgs/valheim.nix { };
      packageText = "pkgs.callPackage (chandlery + \"/nix/pkgs/valheim.nix\") { }";
      port = 2456;
      # World loaded and socket open; PlayFab's under -crossplay.
      readyPattern = "Opened (Steam|PlayFab) server";
      # The game, and Steam's query port: always the game's plus one.
      ports = s: [
        {
          port = s.port;
          proto = "udp";
        }
        {
          port = s.port + 1;
          proto = "udp";
        }
      ];
      prepareArgs = s: [ ];
      # Its whole configuration is its command line; images/valheim/run adds
      # -nographics -batchmode -savedir /data and -password $VALHEIM_PASSWORD.
      args = s: [
        "-port"
        (toString s.port)
      ];
      # The image's CMD, named after the server.
      extraArgs = name: [
        "-name"
        name
        "-world"
        "Dedicated"
        "-public"
        "1"
      ];
      # No Valheim was ever behind loggifly, so there is nothing to carry over.
      rules = [ ];
    };
  };

  runDir = name: "/run/chandlery/${name}";

  serverOptions =
    { name, config, ... }:
    let
      game = games.${config.game};
    in
    {
      options = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Whether to run this server.";
        };

        game = mkOption {
          type = types.enum (lib.attrNames games);
          description = "Which game this server runs.";
        };

        package = mkOption {
          type = types.package;
          default = game.package;
          defaultText = literalExpression game.packageText;
          description = ''
            The Chandlery package of the game: `opt/<game>`, `bin/chandlery-server`
            and `lib/chandlery/{game.env,prepare,stop}`. Built with this system's
            `pkgs`, so its `allowUnfree` decides.
          '';
        };

        packagePath = mkOption {
          type = types.str;
          default = "${config.package}";
          defaultText = literalExpression ''"''${package}"'';
          example = "/nix/var/nix/profiles/chandlery/wrlin";
          description = ''
            What every `Exec*` line runs the game from. By default the package
            itself; point it at a Nix profile (managed by, say, Tidewaiter) and the
            game, its scripts and its version change when the profile does, with
            no change to the unit. The whole of `/nix/store` is then visible
            read-only inside the confinement, since the next version is not in the
            unit's closure.
          '';
        };

        dataDir = mkOption {
          type = types.str;
          default = "/var/lib/chandlery/${name}";
          defaultText = literalExpression ''"/var/lib/chandlery/<name>"'';
          description = ''
            The server's world and config: `/data` inside its confinement, as in
            the image. Created for `user`:`group` if missing; an existing one is
            used as it is, never re-owned.
          '';
        };

        user = mkOption {
          type = types.str;
          default = "chandlery";
          description = "The user the server runs as. `chandlery` is created if used.";
        };

        group = mkOption {
          type = types.str;
          default = "chandlery";
          description = "The group the server runs as. `chandlery` is created if used.";
        };

        port = mkOption {
          type = types.port;
          default = game.port;
          defaultText = literalExpression "19132 (Bedrock), 5520 (Hytale), 2456 (Valheim)";
          description = ''
            The port the server binds. Natively there is no host-side remap, so
            servers of one game on one host each need their own (Hytale's
            5520, 5521, …). Bedrock's is set by rewriting just `server-port` in
            `/data/server.properties`; Hytale's is `--bind 0.0.0.0:<port>` on its
            command line, `config.json` untouched; Valheim's is `-port <port>`,
            and its Steam query port is always this plus one, so two Valheim
            servers want ports two apart.
          '';
        };

        portv6 = mkOption {
          type = types.port;
          default = config.port + 1;
          defaultText = literalExpression "port + 1";
          description = "Bedrock's IPv6 port (`server-portv6`). Two Bedrock servers want ports two apart.";
        };

        ports = mkOption {
          type = types.listOf types.str;
          readOnly = true;
          default = map (p: "${toString p.port}/${p.proto}") (game.ports config);
          defaultText = literalExpression ''[ "19132/udp" "19133/udp" ]'';
          description = "What the server listens on, for a firewall, Portical or Tidewaiter.";
        };

        openFirewall = mkOption {
          type = types.bool;
          default = false;
          description = "Open `ports` in the firewall.";
        };

        extraArgs = mkOption {
          type = types.listOf types.str;
          default = game.extraArgs name;
          defaultText = literalExpression ''[ ] (Bedrock, Hytale), [ "-name" "<name>" "-world" "Dedicated" "-public" "1" ] (Valheim)'';
          description = ''
            Arguments appended to the game's command line, verbatim. Valheim's
            whole configuration is here (its default is the image's `CMD`); its
            password is not: put `VALHEIM_PASSWORD=…` in an `environmentFiles`
            file, which `images/valheim/run` turns into `-password`.
          '';
        };

        environment = mkOption {
          type = types.attrsOf types.str;
          default = { };
          example = {
            TZ = "Europe/London";
          };
          description = "Environment for the server.";
        };

        environmentFiles = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Files of environment for the server (`EnvironmentFile=`), e.g. secrets.";
        };

        machineIdFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "/data/servers/hytale-eldermarch/machine-id";
          description = ''
            A file bound read-only over `/etc/machine-id` inside the confinement,
            for a game that keys something off the machine's identity: Hytale's
            encrypted auth store does, and without one the confined server finds
            no machine-id at all. A file per server keeps that identity with the
            world rather than the host.
          '';
        };

        treesinger = {
          socket = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "/run/treesinger/treesinger.sock";
            description = ''
              Hytale only: the unix socket of a Treesinger broker to mint this
              server's session from at each start (`POST /v1/session`, in
              `images/hytale/run`), into the server's own environment and never
              on its command line. If the broker is absent or not logged in, the
              server boots unauthenticated, with a warning. The socket's
              directory is bound read-only into the confinement and the server
              joins `treesinger.group`. `null`: no broker.
            '';
          };

          group = mkOption {
            type = types.str;
            default = "treesinger";
            description = "The group that may connect to `treesinger.socket`.";
          };
        };

        readyPattern = mkOption {
          type = types.nullOr types.str;
          default = game.readyPattern;
          defaultText = literalExpression ''"Server started\\." (Bedrock), "Hytale Server Booted!" (Hytale), "Opened (Steam|PlayFab) server" (Valheim)'';
          description = ''
            An RE2 matching the line the game prints when players can join: the
            unit is `Type=notify` and becomes active on it. `null` makes it
            `Type=exec`, active as soon as the game is started.
          '';
        };

        startTimeout = mkOption {
          type = types.str;
          default = "15min";
          description = "`TimeoutStartSec`: how long the game may take to print `readyPattern`.";
        };

        stopTimeout = mkOption {
          type = types.str;
          default = "5min";
          description = "`TimeoutStopSec`: how long a stop may take to save before `SIGKILL`.";
        };

        confine = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Confine the server to its own closure, its `dataDir` and its console
            (`systemd.services.<unit>.confinement`). The rest of the hardening stays
            either way; this is the escape hatch.
          '';
        };

        notify = {
          enable = mkOption {
            type = types.bool;
            default = false;
            description = "Notify through Apprise when players join or leave.";
          };

          appriseUrlFile = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "/run/secrets/discord-webhook";
            description = ''
              A file holding the Apprise URL (e.g. a sops secret). Passed with
              `LoadCredential=`, never on a command line.
            '';
          };

          title = mkOption {
            type = types.str;
            default = name;
            description = "The notification title (a `{{ name }}` template, as loggifly's).";
          };

          rules = mkOption {
            type = types.listOf (
              types.submodule {
                options = {
                  regex = mkOption {
                    type = types.str;
                    description = "RE2; Python-style `(?P<name>…)` groups work.";
                  };
                  message = mkOption {
                    type = types.str;
                    description = "The body, with `{{ name }}` for each named group.";
                  };
                };
              }
            );
            default = game.rules;
            defaultText = literalExpression "the game's join/leave lines, as loggifly's labels had them";
            description = "Lines to notify on, in order; each match sends one notification.";
          };
        };
      };
    };

  serviceFor =
    name: s:
    let
      game = games.${s.game};
      run = runDir name;
      tools = "${cfg.tools}/bin";
      # A profile, rather than the package itself: the next version is not in
      # the unit's closure, so the store is mounted whole.
      profileMode = s.packagePath != "${s.package}";
      treesinger = s.treesinger.socket != null;
    in
    {
      description = "Chandlery ${s.game} server ${name}";
      wantedBy = [ "multi-user.target" ];
      requires = [
        "chandlery-${name}.socket"
        "chandlery-${name}-data-dir.service"
      ];
      # After the broker is up (and, through it, the network), so the session
      # is minted at the first try; wanted, not required: without it the
      # server still boots, unauthenticated.
      after = [
        "chandlery-${name}.socket"
        "chandlery-${name}-data-dir.service"
        "network-online.target"
      ]
      ++ lib.optional treesinger "treesinger.service";
      wants = [ "network-online.target" ] ++ lib.optional treesinger "treesinger.service";
      unitConfig.RequiresMountsFor = [ s.dataDir ];

      environment = {
        HOME = "/data";
        CHANDLERY_CONSOLE = "${run}/console";
        CHANDLERY_LOCK = "${run}/private/running";
      }
      // lib.optionalAttrs treesinger { TREESINGER_SOCKET = s.treesinger.socket; }
      // s.environment;

      confinement = mkIf s.confine {
        enable = true;
        mode = "full-apivfs";
      };

      serviceConfig = {
        Type = if s.readyPattern != null then "notify" else "exec";
        NotifyAccess = "main";
        Sockets = [ "chandlery-${name}.socket" ];
        StandardInput = "socket";
        StandardOutput = "journal";
        StandardError = "journal";

        User = s.user;
        Group = s.group;
        # The socket's mode is the access boundary. Unmapped in the unit's user
        # namespace (PrivateUsers), but the kernel checks the real gid.
        SupplementaryGroups = lib.optional treesinger s.treesinger.group;
        UMask = "0022";
        EnvironmentFile = s.environmentFiles;
        WorkingDirectory = "/data";

        # private/opt is /opt inside: chandlery-prepare stages the game there
        # (a tmpfs, like a container's writable layer), and the lock
        # chandlery-ready holds lives beside it.
        RuntimeDirectory = [
          "chandlery/${name}/private"
          "chandlery/${name}/private/opt"
        ];
        RuntimeDirectoryMode = "0700";
        BindPaths = [
          "${s.dataDir}:/data"
          run
          "${run}/private/opt:/opt"
        ];
        BindReadOnlyPaths =
          lib.optionals s.confine [
            "-/etc/resolv.conf"
            "-/etc/hosts"
            "-/etc/nsswitch.conf"
            "-/etc/localtime"
            "-/etc/zoneinfo"
            "-/etc/ssl/certs/ca-certificates.crt"
            # BDS's static OpenSSL was built with OPENSSLDIR=/etc/ssl, so it
            # reads its CAs from /etc/ssl/cert.pem: without one it cannot sign
            # in to Minecraft services, and stops.
            "-/etc/ssl/certs/ca-certificates.crt:/etc/ssl/cert.pem"
            # Its own user's entry, as the image's /etc/passwd has it, and no
            # one else's (chandlery-<name>-data-dir writes them): Unity
            # (Valheim) dereferences getpwuid(getuid()) unchecked, and segfaults
            # without one.
            "${run}/etc/passwd:/etc/passwd"
            "${run}/etc/group:/etc/group"
          ]
          ++ lib.optional (s.machineIdFile != null) "${s.machineIdFile}:/etc/machine-id"
          # The directory, not the socket: a bind of the socket would pin the
          # inode a restarted broker replaces. Optional, so a missing broker
          # means an unauthenticated server, not a failed start.
          ++ lib.optional treesinger "-${dirOf s.treesinger.socket}"
          ++ lib.optionals (s.confine && profileMode) [
            "/nix/store"
            "-/nix/var/nix/profiles"
          ];

        ExecStartPre = "${tools}/chandlery-prepare ${
          escapeSystemdExecArgs ([ s.packagePath ] ++ game.prepareArgs s)
        }";
        ExecStart = "${tools}/chandlery-ready ${
          escapeSystemdExecArgs (
            [
              "--lock"
              "${run}/private/running"
            ]
            ++ lib.optionals (s.readyPattern != null) [
              "--pattern"
              s.readyPattern
            ]
            ++ [
              "--"
              "${s.packagePath}/bin/chandlery-server"
            ]
            ++ game.args s
            ++ s.extraArgs
          )
        }";
        ExecStop = "${tools}/chandlery-stop ${escapeSystemdExecArgs [ s.packagePath ]}";
        # After the stop hook, or without one: the signal Valheim saves on, and
        # one Java treats as it does SIGTERM. A game that exits on it reports 130.
        KillSignal = "SIGINT";
        SuccessExitStatus = [ 130 ];
        TimeoutStartSec = s.startTimeout;
        TimeoutStopSec = s.stopTimeout;
        Restart = "on-failure";
        RestartSec = "10s";

        # Hardening (docs/nix.md, "Hardening"); systemd-analyze security is
        # held under a ceiling by nix/tests/module.nix.
        PrivateUsers = true;
        PrivatePIDs = true;
        ProtectProc = "invisible";
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        SystemCallFilter = [ "@system-service" ];
        SystemCallErrorNumber = "EPERM";
        SystemCallArchitectures = "native";
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
          "AF_NETLINK"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        PrivateTmp = true;
        PrivateDevices = true;
        PrivateIPC = true;
        ProtectHostname = true;
        ProtectClock = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectSystem = "strict";
        ProtectHome = true;
      };
    };

  # Its own unit, not an ExecStartPre=+: systemd sets up the server's mount
  # namespace (which binds dataDir) even for a privileged ExecStartPre, so the
  # directory has to exist before the server's unit starts at all.
  # The confined server's /etc/passwd and /etc/group are written here too,
  # as root and from the host's databases: its own user and groups only, home
  # at /data, as the image's are.
  dataDirFor =
    name: s:
    let
      groups = [ s.group ] ++ lib.optional (s.treesinger.socket != null) s.treesinger.group;
      identity = pkgs.writeShellScript "chandlery-${name}-identity" ''
        set -euo pipefail
        etc=${lib.escapeShellArg "${runDir name}/etc"}
        mkdir -p "$etc"
        umask 0022
        ${pkgs.getent}/bin/getent passwd ${lib.escapeShellArg s.user} \
          | ${pkgs.gawk}/bin/awk -F: -v OFS=: '{ $6 = "/data"; print }' > "$etc/passwd.new"
        for g in ${lib.escapeShellArgs groups}; do
          ${pkgs.getent}/bin/getent group "$g" | ${pkgs.gawk}/bin/awk -F: -v OFS=: '{ print $1, "x", $3, "" }'
        done > "$etc/group.new"
        mv "$etc/passwd.new" "$etc/passwd"
        mv "$etc/group.new" "$etc/group"
      '';
    in
    {
      description = "Chandlery ${s.game} server ${name}: data directory";
      # The server Requires this unit, and a restart of it restarts the server:
      # a switch that changes it (a new chandlery-make-data-dir, after any bump
      # of nixpkgs or the tools) must not restart a server that opted out of
      # restarts on switch, as Tidewaiter's does, its players kicked.
      restartIfChanged = config.systemd.services."chandlery-${name}".restartIfChanged;
      unitConfig.RequiresMountsFor = [ s.dataDir ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = [
          "${cfg.tools}/bin/chandlery-make-data-dir ${
            escapeSystemdExecArgs [
              s.dataDir
              s.user
              s.group
            ]
          }"
        ]
        ++ lib.optional s.confine identity;
      };
    };

  socketFor = name: s: {
    description = "Chandlery ${s.game} server ${name}: console";
    # The console lives exactly as long as the server, as in Docker; a write to
    # it never starts a stopped server.
    partOf = [ "chandlery-${name}.service" ];
    socketConfig = {
      ListenFIFO = "${runDir name}/console";
      SocketUser = s.user;
      SocketGroup = s.group;
      SocketMode = "0600";
      DirectoryMode = "0755";
      RemoveOnStop = true;
      # A line the server never read is not left for the next one.
      FlushPending = true;
    };
  };

  notifyFor =
    name: s:
    let
      settings = pkgs.writeText "chandlery-${name}-notify.json" (
        builtins.toJSON {
          unit = "chandlery-${name}.service";
          inherit (s.notify) title rules;
          apprise = lib.getExe cfg.apprise;
          # Nowhere to keep Apprise's persistent cache, and nothing worth keeping.
          appriseArgs = [ "--storage-mode=memory" ];
          journalctl = "${config.systemd.package}/bin/journalctl";
        }
      );
    in
    {
      description = "Chandlery ${s.game} server ${name}: join/leave notifications";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        ExecStart = "${cfg.tools}/bin/chandlery-notify --config ${settings}";
        LoadCredential = [ "apprise-url:${s.notify.appriseUrlFile}" ];
        DynamicUser = true;
        SupplementaryGroups = [ "systemd-journal" ];
        Restart = "always";
        RestartSec = "10s";

        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        SystemCallFilter = [ "@system-service" ];
        SystemCallArchitectures = "native";
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        PrivateTmp = true;
        PrivateDevices = true;
        PrivateIPC = true;
        ProtectProc = "invisible";
        ProtectHostname = true;
        ProtectClock = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectSystem = "strict";
        ProtectHome = true;
      };
    };

  usesDefault = attr: lib.any (s: s.${attr} == "chandlery") (lib.attrValues servers);
in
{
  options.services.chandlery = {
    servers = mkOption {
      type = types.attrsOf (types.submodule serverOptions);
      default = { };
      example = literalExpression ''
        {
          wrlin = {
            game = "bedrock";
            user = "dan";
            group = "users";
            dataDir = "/data/servers/wrlin_survival/serverfiles";
            notify = {
              enable = true;
              title = "WRLIN Survival";
              appriseUrlFile = config.sops.secrets.discord-webhook.path;
            };
          };
        }
      '';
      description = ''
        Game servers, each `chandlery-<name>.service` with its console at
        `/run/chandlery/<name>/console` (`chandlery-console <name> <command>`).
      '';
    };

    tools = mkOption {
      type = types.package;
      default = pkgs.callPackage ./pkgs/chandlery-systemd.nix { };
      defaultText = literalExpression "pkgs.callPackage (chandlery + \"/nix/pkgs/chandlery-systemd.nix\") { }";
      description = "The native tools: `chandlery-console` on the host, and what the units run.";
    };

    apprise = mkOption {
      type = types.package;
      default = pkgs.apprise;
      defaultText = literalExpression "pkgs.apprise";
      description = "The Apprise CLI join/leave notifications are sent with.";
    };
  };

  config = mkIf (servers != { }) {
    assertions =
      lib.mapAttrsToList (name: _: {
        assertion = builtins.match "[A-Za-z0-9_][A-Za-z0-9_.-]*" name != null;
        message = "services.chandlery.servers.${name}: a name is a unit and a path component: letters, digits, '_', '.' and '-'.";
      }) servers
      ++ lib.mapAttrsToList (name: s: {
        assertion = s.treesinger.socket != null -> s.game == "hytale";
        message = "services.chandlery.servers.${name}.treesinger.socket is for Hytale servers.";
      }) servers
      ++ lib.mapAttrsToList (name: s: {
        assertion = s.treesinger.socket == null || lib.hasPrefix "/" s.treesinger.socket;
        message = "services.chandlery.servers.${name}.treesinger.socket must be an absolute path.";
      }) servers
      ++ lib.mapAttrsToList (name: s: {
        assertion = s.notify.enable -> s.notify.appriseUrlFile != null;
        message = "services.chandlery.servers.${name}.notify.enable needs notify.appriseUrlFile.";
      }) servers
      ++ (
        # Each Valheim server also takes port + 1, and each Bedrock one portv6:
        # two servers apart is easy to miss, and found only when one cannot bind.
        let
          clashes = lib.filter (p: lib.length p.servers > 1) (
            lib.mapAttrsToList
              (port: names: {
                inherit port;
                servers = lib.unique names;
              })
              (
                lib.zipAttrs (
                  lib.concatLists (lib.mapAttrsToList (name: s: map (p: { ${p} = name; }) s.ports) servers)
                )
              )
          );
        in
        map (c: {
          assertion = false;
          message = "services.chandlery.servers: ${lib.concatStringsSep ", " c.servers} all listen on ${c.port}.";
        }) clashes
      );

    environment.systemPackages = [ cfg.tools ];

    systemd.services =
      lib.mapAttrs' (name: s: lib.nameValuePair "chandlery-${name}" (serviceFor name s)) servers
      // lib.mapAttrs' (
        name: s: lib.nameValuePair "chandlery-${name}-data-dir" (dataDirFor name s)
      ) servers
      // lib.mapAttrs' (name: s: lib.nameValuePair "chandlery-${name}-notify" (notifyFor name s)) (
        lib.filterAttrs (_: s: s.notify.enable) servers
      );

    systemd.sockets = lib.mapAttrs' (
      name: s: lib.nameValuePair "chandlery-${name}" (socketFor name s)
    ) servers;

    users.users = lib.mkIf (usesDefault "user") {
      chandlery = {
        isSystemUser = true;
        group = "chandlery";
        home = "/var/lib/chandlery";
      };
    };
    users.groups =
      lib.optionalAttrs (usesDefault "group" || usesDefault "user") { chandlery = { }; }
      # So a server can start, unauthenticated, before Treesinger is
      # installed; Treesinger's module declares the same group.
      // lib.listToAttrs (
        map (s: lib.nameValuePair s.treesinger.group { }) (
          lib.filter (s: s.treesinger.socket != null) (lib.attrValues servers)
        )
      );

    networking.firewall =
      let
        open = lib.concatMap (s: lib.optionals s.openFirewall (games.${s.game}.ports s)) (
          lib.attrValues servers
        );
        on = proto: map (p: p.port) (lib.filter (p: p.proto == proto) open);
      in
      {
        allowedUDPPorts = on "udp";
        allowedTCPPorts = on "tcp";
      };
  };
}
