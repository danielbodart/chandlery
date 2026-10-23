# Valheim's adapter (images/valheim/{run,prepare,health}) in the unit the
# module renders, on the fake server the Docker adapter tests use: -port and the
# image's CMD on its command line, the password from an environment file and
# nowhere in the unit, Steam's client library wired under /data, the A2S health
# probe, and a stop by SIGINT — the signal Valheim saves on — with no stop hook.
{ self }:
{ hostPkgs, ... }:

let
  fake = import ./fake-valheim.nix { pkgs = hostPkgs; };
in
{
  name = "chandlery-valheim";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ self.nixosModules.default ];
      virtualisation.memorySize = 1024;

      users.users.dan = {
        isNormalUser = true;
        group = "users";
      };

      # As a sops secret would arrive.
      environment.etc."valheim-harbour.env" = {
        text = "VALHEIM_PASSWORD=hunter22\n";
        mode = "0400";
      };

      services.chandlery.servers = {
        # Dan's shape: a static user, its own port, its password a secret, its
        # flags its own.
        harbour = {
          game = "valheim";
          package = fake;
          user = "dan";
          group = "users";
          dataDir = "/data/servers/valheim-harbour";
          port = 2466;
          environmentFiles = [ "/etc/valheim-harbour.env" ];
          extraArgs = [
            "-name"
            "Harbour"
            "-world"
            "Longship"
            "-crossplay"
          ];
          # The fake's boot line.
          readyPattern = "fake-valheim: listening";
          openFirewall = true;
        };
        # Every default: port 2456, the image's CMD, the real ready line.
        dedicated = {
          game = "valheim";
          package = fake;
        };
      };
    };

  testScript = ''
    import re

    def journal(unit):
        return machine.succeed(f"journalctl -o cat -u chandlery-{unit}.service")

    def show(unit, prop):
        return machine.succeed(f"systemctl show -P {prop} chandlery-{unit}.service").strip()

    def args(unit):
        machine.wait_until_succeeds(f"journalctl -o cat -u chandlery-{unit}.service | grep -q '^fake-valheim: args '")
        m = re.search(r"^fake-valheim: args (.*)$", journal(unit), re.M)
        assert m, journal(unit)
        return m.group(1)

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("chandlery-harbour.service")
    machine.wait_for_unit("chandlery-dedicated.service")

    with subtest("ready on the line it is given, or on the real server's own"):
        assert show("harbour", "Type") == "notify"
        assert show("harbour", "StatusText") == "fake-valheim: listening on udp/2466 (query udp/2467)"
        assert show("dedicated", "Type") == "notify"
        assert show("dedicated", "StatusText") == "Opened Steam server"

    with subtest("its port, its flags, and the adapter's non-negotiables"):
        a = args("harbour")
        assert a.startswith("-nographics -batchmode -savedir /data -password hunter22 "), a
        assert "-port 2466 -name Harbour -world Longship -crossplay" in a, a
        d = args("dedicated")
        assert d.endswith("-port 2456 -name dedicated -world Dedicated -public 1"), d

    with subtest("the password comes from its environment file, never the unit"):
        unit = machine.succeed("systemctl cat chandlery-harbour.service")
        assert "hunter22" not in unit, unit
        assert "EnvironmentFile=/etc/valheim-harbour.env" in unit, unit
        assert "-password  -port 2456" in args("dedicated")

    with subtest("Steam's client library is wired under its /data, at the game's own"):
        target = machine.succeed("readlink /data/servers/valheim-harbour/.steam/sdk64/steamclient.so").strip()
        assert target == "/opt/valheim/steamclient.so", target
        machine.succeed("test -d /data/servers/valheim-harbour/worlds_local")
        assert machine.succeed("stat -c %U:%G /data/servers/valheim-harbour/.steam").strip() == "dan:users"

    with subtest("both ports, and the firewall open for them"):
        rules = machine.succeed("(iptables-save; nft list ruleset) 2>/dev/null || true")
        assert "2466" in rules and "2467" in rules, rules

    with subtest("the package's health probe asks it over A2S"):
        out = machine.succeed("${fake}/lib/chandlery/health")
        assert "players=0/10" in out, out

    with subtest("stop has no hook: SIGINT, which Valheim saves on, and never SIGTERM"):
        machine.succeed("systemctl stop chandlery-harbour.service")
        log = journal("harbour")
        assert "no stop hook; stopping with the kill signal" in log, log
        assert "fake-valheim: world saved" in log, log
        assert "ignoring SIGTERM" not in log, log
        assert show("harbour", "Result") == "success"

    with subtest("systemd-analyze security holds the module's ceiling"):
        out = machine.succeed("systemd-analyze security --no-pager chandlery-dedicated.service")
        m = re.search(r"Overall exposure level for \S+: ([0-9.]+)", out)
        assert m, out
        exposure = float(m.group(1))
        print(f"chandlery-dedicated: exposure {exposure}")
        assert exposure <= 1.5, out
  '';
}
