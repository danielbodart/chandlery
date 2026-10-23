# The unit mechanics, on the real Bedrock adapter around a fake BDS: fast, no
# download. Console FIFO, readiness, save on stop, crash restart, ports set
# without clobbering the operator's file, confinement, PrivatePIDs, the
# systemd-analyze exposure ceiling, a profile as packagePath, notifications.
{ self }:
{ hostPkgs, ... }:

let
  fake = import ./fake-bds.nix { pkgs = hostPkgs; };
  fakeNext = import ./fake-bds.nix {
    pkgs = hostPkgs;
    version = "0.0.2";
  };
  # The exposure systemd-analyze security reports for a game unit, at most.
  # Measured 1.3 (systemd 260); a regression in the hardening fails here.
  exposureCeiling = 1.5;
in
{
  name = "chandlery-module";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ self.nixosModules.default ];
      virtualisation.memorySize = 1536;

      users.users.gamer = {
        isNormalUser = true;
        group = "users";
      };

      environment.etc."alpha-machine-id".text = "0123456789abcdef0123456789abcdef\n";
      environment.etc."apprise-url" = {
        text = "json://127.0.0.1:8000/hook\n";
        mode = "0400";
      };

      services.chandlery.servers = {
        # Dan's shape: a static user, an existing tree's dataDir, notifications.
        alpha = {
          game = "bedrock";
          package = fake;
          user = "gamer";
          group = "users";
          dataDir = "/srv/games/alpha";
          port = 19140;
          machineIdFile = "/etc/alpha-machine-id";
          environment.FAKE_BDS_DELAY = "3";
          notify = {
            enable = true;
            title = "Alpha";
            appriseUrlFile = "/etc/apprise-url";
          };
        };
        # Every default.
        beta = {
          game = "bedrock";
          package = fake;
        };
        # Its game from a profile, as Tidewaiter would manage it.
        gamma = {
          game = "bedrock";
          package = fake;
          packagePath = "/nix/var/nix/profiles/chandlery/gamma";
          port = 19150;
        };
        # The escape hatch.
        delta = {
          game = "bedrock";
          package = fake;
          port = 19160;
          confine = false;
        };
      };

      systemd.tmpfiles.rules = [ "L+ /nix/var/nix/profiles/chandlery/gamma - - - - ${fake}" ];
      system.extraDependencies = [ fakeNext ];

      # Stands in for Discord: Apprise's json:// posts land here.
      systemd.services.hook = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.StateDirectory = "hook";
        script = ''
          exec ${pkgs.python3}/bin/python3 -c '
          import http.server
          class Hook(http.server.BaseHTTPRequestHandler):
              def do_POST(self):
                  body = self.rfile.read(int(self.headers["Content-Length"]))
                  with open("/var/lib/hook/received", "ab") as f:
                      f.write(body + b"\n")
                  self.send_response(200)
                  self.end_headers()
          http.server.HTTPServer(("127.0.0.1", 8000), Hook).serve_forever()
          '
        '';
      };
    };

  testScript = ''
    import json
    import re

    def journal(unit):
        return machine.succeed(f"journalctl -o cat -u chandlery-{unit}.service")

    def probe(unit):
        before = journal(unit).count("probe: done")
        machine.succeed(f"chandlery-console {unit} probe")
        machine.wait_until_succeeds(f"test $(journalctl -o cat -u chandlery-{unit}.service | grep -c 'probe: done') -gt {before}")
        found = {}
        for line in journal(unit).splitlines():
            m = re.match(r"probe: (\S+?)=(.*)", line)
            if m:
                found[m.group(1)] = m.group(2).strip()
        return found

    def show(unit, prop):
        return machine.succeed(f"systemctl show -P {prop} chandlery-{unit}.service").strip()

    machine.wait_for_unit("multi-user.target")
    for unit in ["alpha", "beta", "gamma", "delta"]:
        machine.wait_for_unit(f"chandlery-{unit}.service")

    with subtest("the console is a FIFO only the server's user can write"):
        assert machine.succeed("stat -c '%F %U %a' /run/chandlery/alpha/console").strip() == "fifo gamer 600"
        assert machine.succeed("stat -c '%F %U %a' /run/chandlery/beta/console").strip() == "fifo chandlery 600"

    with subtest("activating until the game says it is up, then active"):
        machine.succeed("systemctl stop chandlery-alpha.service")
        machine.succeed("systemctl start --no-block chandlery-alpha.service")
        machine.sleep(1)
        assert show("alpha", "ActiveState") == "activating", show("alpha", "ActiveState")
        machine.wait_for_unit("chandlery-alpha.service")
        assert show("alpha", "StatusText") == "[INFO] Server started."

    with subtest("chandlery-console types at the game"):
        machine.succeed("chandlery-console alpha say hello there")
        machine.wait_until_succeeds("journalctl -o cat -u chandlery-alpha.service | grep -qF '[Server] hello there'")

    with subtest("a missing dataDir is created for the server's user; an existing one is left alone"):
        assert machine.succeed("stat -c '%U %a' /var/lib/chandlery/beta").strip() == "chandlery 750"
        machine.succeed("systemctl stop chandlery-alpha.service; chown root:root /srv/games; chmod 0711 /srv/games")
        machine.succeed("systemctl start chandlery-alpha.service")
        assert machine.succeed("stat -c '%U %a' /srv/games").strip() == "root 711"

    with subtest("the ports are set in server.properties, and nothing else in it is touched"):
        props = machine.succeed("cat /srv/games/alpha/server.properties")
        assert "server-port=19140\n" in props and "server-portv6=19141\n" in props, props
        assert "IPv4 supported, port: 19140" in journal("alpha")
        machine.succeed("echo 'my-own-key=kept # mine' >> /srv/games/alpha/server.properties")
        machine.succeed("sed -i 's/^server-name=.*/server-name=Alpha World/' /srv/games/alpha/server.properties")
        machine.succeed("systemctl restart chandlery-alpha.service")
        props = machine.succeed("cat /srv/games/alpha/server.properties")
        assert "my-own-key=kept # mine" in props and "server-name=Alpha World" in props, props
        assert "server-port=19132\n" in machine.succeed("cat /var/lib/chandlery/beta/server.properties")

    with subtest("confined: its own world at /data, nothing else of the host"):
        p = probe("alpha")
        uid = machine.succeed("id -u gamer").strip()
        assert p["ids"] == f"{uid}:100", p
        assert "server.properties" in p["data"] and "worlds" in p["data"], p
        assert "No such file" in p["srv"] or p["srv"] == "", p
        assert p["home"] == "" or "No such file" in p["home"] or "Permission denied" in p["home"], p
        assert p["machine-id"] == "0123456789abcdef0123456789abcdef", p
        assert p["cwd"] == "/opt/bedrock /data/worlds", p
        closure = int(p["store"])
        assert closure < 100, f"{closure} store paths visible"

    with subtest("PrivatePIDs: the wrapper is PID 1 and the host's processes are out of sight"):
        assert p["pid1"] == "chandlery-ready", p
        assert int(p["pids"]) < 6, p

    with subtest("stop types the save-and-quit and waits for it, without SIGKILL"):
        machine.succeed("rm -f /srv/games/alpha/worlds/saved")
        machine.succeed("systemctl stop chandlery-alpha.service")
        log = journal("alpha")
        assert "Quit correctly" in log, log
        assert "ignoring SIGTERM" not in log
        machine.succeed("test -s /srv/games/alpha/worlds/saved")
        assert show("alpha", "Result") == "success"
        assert show("alpha", "ExecMainStatus") == "0"
        machine.fail("test -e /run/chandlery/alpha/console")
        machine.fail("systemctl is-active chandlery-alpha.socket")

    with subtest("a write to a stopped server's console does not start it"):
        machine.fail("chandlery-console alpha say anyone")
        machine.fail("systemctl is-active chandlery-alpha.service")

    with subtest("a crash restarts it"):
        machine.succeed("systemctl start chandlery-alpha.service")
        before = show("alpha", "MainPID")
        machine.succeed("chandlery-console alpha crash")
        # From the journal, not NRestarts: the console socket is PartOf the
        # server, so it restarts with it, and its start can take over the
        # restart job and reset the counter (two runs of three here).
        machine.wait_until_succeeds("journalctl -u chandlery-alpha.service | grep -q 'Scheduled restart job, restart counter is at 1'", timeout=60)
        machine.wait_for_unit("chandlery-alpha.service")
        assert show("alpha", "MainPID") != before

    with subtest("systemd-analyze security holds the ceiling"):
        for unit in ["alpha", "gamma"]:
            out = machine.succeed(f"systemd-analyze security --no-pager chandlery-{unit}.service")
            m = re.search(r"Overall exposure level for \S+: ([0-9.]+)", out)
            assert m, out
            exposure = float(m.group(1))
            print(f"chandlery-{unit}: exposure {exposure}")
            assert exposure <= ${toString exposureCeiling}, out

    with subtest("from a profile: the store is visible whole, and repointing it changes the game"):
        p = probe("gamma")
        assert int(p["store"]) > closure, p
        assert "Version: 0.0.1" in journal("gamma")
        machine.succeed("ln -sfn ${fakeNext} /nix/var/nix/profiles/chandlery/gamma")
        machine.succeed("systemctl restart chandlery-gamma.service")
        assert "Version: 0.0.2" in journal("gamma")

    with subtest("unconfined: the hardening stays, the host's filesystem is visible"):
        p = probe("delta")
        assert "home" in p["root"].split(), p
        assert p["pid1"] == "chandlery-ready", p

    with subtest("joins and leaves are sent through Apprise, the URL never on a command line"):
        machine.wait_for_unit("chandlery-alpha-notify.service")
        machine.wait_for_unit("hook.service")
        machine.sleep(2)
        machine.succeed("chandlery-console alpha join Steve The Great")
        machine.succeed("chandlery-console alpha say nobody joined")
        machine.succeed("chandlery-console alpha leave Steve The Great")
        machine.wait_until_succeeds("test $(wc -l < /var/lib/hook/received) -ge 2", timeout=60)
        machine.sleep(2)
        sent = [json.loads(l) for l in machine.succeed("cat /var/lib/hook/received").splitlines()]
        assert [(s["title"], s["message"]) for s in sent] == [
            ("Alpha", "\U0001F7E2 Steve The Great joined"),
            ("Alpha", "\U0001F534 Steve The Great left"),
        ], sent
        # The bracket keeps grep's own command line from matching.
        machine.fail("grep -l 'json:/[/]' /proc/[0-9]*/cmdline")
  '';
}
