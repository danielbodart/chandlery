# The plain-systemd templates (systemd/units), with no module: chandlery@.service
# and chandlery@.socket as `make install-systemd` installs them, the packages at
# /var/lib/chandlery-packages/<name>, each server's settings in
# /etc/chandlery/<name>.env. On the fake Bedrock and Valheim packages: readiness
# from the package's game.env, the console, CHANDLERY_SET and CHANDLERY_ARGS,
# no other world in sight, a stop that saves, repointing a package to upgrade,
# and the exposure systemd-analyze reports.
{ self }:
{ hostPkgs, ... }:

let
  fakeBedrock = import ./fake-bds.nix { pkgs = hostPkgs; };
  fakeBedrockNext = import ./fake-bds.nix {
    pkgs = hostPkgs;
    version = "0.0.2";
  };
  fakeValheim = import ./fake-valheim.nix { pkgs = hostPkgs; };
  tools = self.packages.${hostPkgs.stdenv.hostPlatform.system}.chandlery-systemd;
  # Where systemd.packages looks for units: the templates as installed.
  units = hostPkgs.runCommand "chandlery-template-units" { } ''
    mkdir -p $out/lib/systemd/system
    ln -s ${tools}/share/chandlery/systemd/* $out/lib/systemd/system/
  '';
in
{
  name = "chandlery-template";

  nodes.machine =
    { ... }:
    {
      virtualisation.memorySize = 1024;
      environment.systemPackages = [ tools ];
      systemd.packages = [ units ];

      # As systemd-sysusers makes it from systemd/units/chandlery.sysusers.
      users.users.chandlery = {
        isSystemUser = true;
        group = "chandlery";
        home = "/var/lib/chandlery";
      };
      users.groups.chandlery = { };

      systemd.tmpfiles.rules = [
        "L+ /var/lib/chandlery-packages/wrlin - - - - ${fakeBedrock}"
        "L+ /var/lib/chandlery-packages/harbour - - - - ${fakeValheim}"
        # Another world on the host, which neither server should see.
        "d /srv/elsewhere 0755 root root -"
      ];
      system.extraDependencies = [ fakeBedrockNext ];

      environment.etc."chandlery/wrlin.env".text = ''
        CHANDLERY_SET=server-port=19140 server-portv6=19141
      '';
      environment.etc."chandlery/harbour.env".text = ''
        CHANDLERY_ARGS=-name Harbour -world Longship -port 2466
        VALHEIM_PASSWORD=hunter22
      '';
    };

  testScript = ''
    import re

    def journal(unit):
        return machine.succeed(f"journalctl -o cat -u chandlery@{unit}.service")

    def show(unit, prop):
        return machine.succeed(f"systemctl show -P {prop} chandlery@{unit}.service").strip()

    machine.wait_for_unit("multi-user.target")
    machine.succeed("systemctl start chandlery@wrlin.service chandlery@harbour.service")

    with subtest("ready on the line its package's game.env names"):
        assert show("wrlin", "ActiveState") == "active"
        assert show("wrlin", "StatusText") == "[INFO] Server started."
        assert show("harbour", "StatusText") == "Opened Steam server"

    with subtest("its world in its state directory, its console a FIFO only its user can write"):
        machine.succeed("test -s /var/lib/chandlery/wrlin/server.properties")
        assert machine.succeed("stat -c '%F %U %a' /run/chandlery/wrlin/console").strip() == "fifo chandlery 600"
        machine.succeed("chandlery-console wrlin say hello there")
        machine.wait_until_succeeds("journalctl -o cat -u chandlery@wrlin.service | grep -qF '[Server] hello there'")

    with subtest("CHANDLERY_SET sets its server.properties keys, and nothing else"):
        props = machine.succeed("cat /var/lib/chandlery/wrlin/server.properties")
        assert "server-port=19140\n" in props and "server-portv6=19141\n" in props, props
        assert "server-name=Dedicated Server" in props, props
        assert "IPv4 supported, port: 19140" in journal("wrlin")

    with subtest("CHANDLERY_ARGS is its command line, and the adapter adds the rest"):
        m = re.search(r"^fake-valheim: args (.*)$", journal("harbour"), re.M)
        assert m, journal("harbour")
        assert m.group(1) == "-nographics -batchmode -savedir /data -password hunter22 -name Harbour -world Longship -port 2466", m.group(1)

    with subtest("no other world in sight"):
        machine.succeed("chandlery-console wrlin probe")
        machine.wait_until_succeeds("journalctl -o cat -u chandlery@wrlin.service | grep -q 'probe: done'")
        p = dict(re.findall(r"^probe: (\S+)=(.*)$", journal("wrlin"), re.M))
        assert "server.properties" in p["data"], p
        assert p["srv"] == "" or "Permission denied" in p["srv"], p
        assert p["pid1"] == "chandlery-ready", p
        pid = machine.succeed("systemctl show -P MainPID chandlery@wrlin.service").strip()
        others = machine.succeed(f"ls -A /proc/{pid}/root/var/lib/chandlery").split()
        assert others == ["wrlin"], f"other servers' worlds are visible: {others}"

    with subtest("stop types the save-and-quit and waits for it; Valheim's is SIGINT"):
        machine.succeed("systemctl stop chandlery@wrlin.service chandlery@harbour.service")
        assert "Quit correctly" in journal("wrlin")
        machine.succeed("test -s /var/lib/chandlery/wrlin/worlds/saved")
        assert show("wrlin", "Result") == "success"
        log = journal("harbour")
        assert "fake-valheim: world saved" in log and "ignoring SIGTERM" not in log, log
        assert show("harbour", "Result") == "success"

    with subtest("repointing its package and restarting upgrades it"):
        machine.succeed("ln -sfn ${fakeBedrockNext} /var/lib/chandlery-packages/wrlin")
        machine.succeed("systemctl start chandlery@wrlin.service")
        assert "[INFO] Version: 0.0.2" in journal("wrlin")

    with subtest("systemd-analyze security"):
        out = machine.succeed("systemd-analyze security --no-pager chandlery@wrlin.service")
        m = re.search(r"Overall exposure level for \S+: ([0-9.]+)", out)
        assert m, out
        exposure = float(m.group(1))
        print(f"chandlery@wrlin: exposure {exposure}")
        assert exposure <= 1.5, out
  '';
}
