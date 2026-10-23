# Hytale's adapter (images/hytale/{run,prepare,stop-hook}) in the unit the
# module renders, on the fake java the Docker adapter tests use and a fake
# Treesinger: the session minted over the broker's unix socket, through the
# treesinger group under PrivateUsers, into the server's environment and not
# its argv; an unauthenticated boot when the broker is gone; --bind with the
# server's own port; the per-server machine-id; /stop on the console at stop.
{ self }:
{ hostPkgs, ... }:

let
  fake = import ./fake-hytale.nix { pkgs = hostPkgs; };
in
{
  name = "chandlery-hytale";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ self.nixosModules.default ];
      virtualisation.memorySize = 1536;

      users.users.dan = {
        isNormalUser = true;
        group = "users";
      };

      # Dan's shape: the existing tree, its pinned machine-id beside the world.
      systemd.tmpfiles.rules = [
        "d /data/servers/hytale-eldermarch 0755 dan users -"
        "f+ /data/servers/hytale-eldermarch/machine-id 0444 dan users - 0123456789abcdef0123456789abcdef"
      ];

      services.chandlery.servers = {
        eldermarch = {
          game = "hytale";
          package = fake;
          user = "dan";
          group = "users";
          dataDir = "/data/servers/hytale-eldermarch";
          port = 5520;
          machineIdFile = "/data/servers/hytale-eldermarch/machine-id";
          treesinger.socket = "/run/treesinger/treesinger.sock";
          # The fake's boot line.
          readyPattern = "fake-hytale: listening";
          environment.TZ = "Europe/London";
          notify = {
            enable = true;
            title = "Hytale Eldermarch";
            appriseUrlFile = "/etc/apprise-url";
          };
        };
        # Every default but readiness: no broker, Type=exec.
        worthengard = {
          game = "hytale";
          package = fake;
          port = 5521;
          readyPattern = null;
        };
      };

      environment.etc."apprise-url" = {
        text = "json://127.0.0.1:8000/hook\n";
        mode = "0400";
      };
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

      # Stands in for Treesinger, as its module runs it: its own user in the
      # treesinger group, a socket 0660 in a 0750 runtime directory.
      users.users.treesinger = {
        isSystemUser = true;
        group = "treesinger";
      };
      systemd.services.treesinger = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          User = "treesinger";
          Group = "treesinger";
          RuntimeDirectory = "treesinger";
          RuntimeDirectoryMode = "0750";
          RuntimeDirectoryPreserve = true;
          UMask = "0117";
        };
        script = ''
          exec ${pkgs.python3}/bin/python3 -c '
          import http.server, socketserver
          class Broker(http.server.BaseHTTPRequestHandler):
              def do_POST(self):
                  body = b"{\"sessionToken\":\"sess.aaa.bbb\",\"identityToken\":\"id.xxx.yyy\",\"expiresAt\":\"2026-01-07T15:00:00Z\"}"
                  self.send_response(200 if self.path == "/v1/session" else 404)
                  self.send_header("Content-Length", str(len(body)))
                  self.end_headers()
                  self.wfile.write(body)
          class Server(socketserver.UnixStreamServer):
              def get_request(self):
                  return self.socket.accept()[0], ("unix", 0)
          Server("/run/treesinger/treesinger.sock", Broker).serve_forever()
          '
        '';
      };
    };

  testScript = ''
    import json
    import re

    def journal(unit):
        return machine.succeed(f"journalctl -o cat -u chandlery-{unit}.service")

    def show(unit, prop):
        return machine.succeed(f"systemctl show -P {prop} chandlery-{unit}.service").strip()

    def java(unit):
        # The game: chandlery-ready's child, as the host sees it.
        main = show(unit, "MainPID")
        return machine.succeed(f"pgrep -P {main}").strip().splitlines()[0]

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("chandlery-eldermarch.service")
    machine.wait_for_unit("chandlery-worthengard.service")

    with subtest("ready on the line it is given, or as soon as it runs with none"):
        assert show("eldermarch", "Type") == "notify"
        assert show("eldermarch", "StatusText") == "fake-hytale: listening"
        assert show("worthengard", "Type") == "exec"

    with subtest("its session comes from Treesinger's socket, into its environment, never its argv"):
        log = journal("eldermarch")
        assert "authenticated via Treesinger (/run/treesinger/treesinger.sock)" in log, log
        assert "fake-java: session sess.aaa.bbb identity id.xxx.yyy" in log, log
        pid = java("eldermarch")
        environ = machine.succeed(f"tr '\\0' '\\n' < /proc/{pid}/environ")
        assert "HYTALE_SERVER_SESSION_TOKEN=sess.aaa.bbb" in environ, environ
        cmdline = machine.succeed(f"tr '\\0' ' ' < /proc/{pid}/cmdline")
        assert "sess.aaa" not in cmdline and "id.xxx" not in cmdline, cmdline

    with subtest("the treesinger group is its supplementary group, unmapped in its user namespace"):
        assert "SupplementaryGroups=treesinger" in machine.succeed("systemctl cat chandlery-eldermarch.service")
        assert show("eldermarch", "PrivateUsers") == "yes"

    with subtest("it binds its own port, on its command line"):
        m = re.search(r"^fake-java: args (.*)$", journal("eldermarch"), re.M)
        assert m, journal("eldermarch")
        args = m.group(1)
        assert "--bind 0.0.0.0:5520" in args, args
        assert "--assets /opt/hytale/Assets" in args, args
        assert "--bind 0.0.0.0:5521" in journal("worthengard")

    with subtest("it sees its own machine-id, and only its broker's directory"):
        pid = java("eldermarch")
        assert machine.succeed(f"cat /proc/{pid}/root/etc/machine-id").strip() == "0123456789abcdef0123456789abcdef"
        assert machine.succeed(f"ls /proc/{pid}/root/run/treesinger").split() == ["treesinger.sock"]
        machine.fail(f"test -e /proc/{pid}/root/data/servers")
        machine.succeed(f"test -d /proc/{pid}/root/data/universe")
        other = java("worthengard")
        machine.fail(f"test -e /proc/{other}/root/run/treesinger")
        machine.fail(f"grep -q 0123456789abcdef /proc/{other}/root/etc/machine-id")

    with subtest("without a broker it boots unauthenticated, with a warning"):
        log = journal("worthengard")
        assert "Treesinger" not in log, log
        assert "fake-java: session none identity none" in log, log
        machine.succeed("systemctl stop treesinger.service; rm -f /run/treesinger/treesinger.sock")
        # The server Wants= the broker: restart it alone, as if the broker had failed.
        machine.succeed("systemctl restart --job-mode=ignore-dependencies chandlery-eldermarch.service")
        log = journal("eldermarch")
        assert "could not reach Treesinger at /run/treesinger/treesinger.sock; booting unauthenticated" in log, log
        assert show("eldermarch", "ActiveState") == "active"
        machine.succeed("systemctl start treesinger.service")

    with subtest("chandlery-console types at the game"):
        machine.succeed("chandlery-console eldermarch /who")
        machine.wait_until_succeeds("journalctl -o cat -u chandlery-eldermarch.service | grep -qF 'fake-hytale: console /who'")

    with subtest("joins and leaves notify with loggifly's Hytale rules"):
        # The fake echoes each console line, so a typed line is a log line.
        machine.wait_for_unit("chandlery-eldermarch-notify.service")
        machine.wait_for_unit("hook.service")
        machine.sleep(2)
        machine.succeed("chandlery-console eldermarch \"[Universe] Player 'Steve' joined world 'default'\"")
        machine.succeed("chandlery-console eldermarch \"[Universe|P] Removing player 'Steve' (0e2f)\"")
        machine.wait_until_succeeds("test $(wc -l < /var/lib/hook/received) -ge 2", timeout=60)
        sent = [json.loads(l) for l in machine.succeed("cat /var/lib/hook/received").splitlines()]
        assert [(s["title"], s["message"]) for s in sent] == [
            ("Hytale Eldermarch", "\U0001F7E2 Steve joined"),
            ("Hytale Eldermarch", "\U0001F534 Steve left"),
        ], sent

    with subtest("stop types /stop and waits for the save, without a signal"):
        machine.succeed("systemctl stop chandlery-eldermarch.service")
        log = journal("eldermarch")
        assert log.rfind("fake-hytale: console /stop") < log.rfind("fake-hytale: saving world"), log
        assert show("eldermarch", "Result") == "success"
        assert show("eldermarch", "ExecMainStatus") == "0"

    with subtest("systemd-analyze security holds the module's ceiling"):
        out = machine.succeed("systemd-analyze security --no-pager chandlery-eldermarch.service")
        m = re.search(r"Overall exposure level for \S+: ([0-9.]+)", out)
        assert m, out
        exposure = float(m.group(1))
        print(f"chandlery-eldermarch: exposure {exposure}")
        assert exposure <= 1.5, out
  '';
}
