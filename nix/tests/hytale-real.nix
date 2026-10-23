# The real Hytale server, from the published image's layers, in the confined
# unit the module renders: it boots (offline: the VM has no internet, and no
# Treesinger) and is ready on its own boot line, binds the port it is given,
# keys its auth store off the per-server machine-id, answers the console, and
# /stop saves and exits cleanly. Heavy — 1.8 GB of layers, 3.4 GB unpacked, a 4 GB JVM — so
# it is not in `checks`: `nix build .#heavyChecks.hytale-vm`
# (docs/nix.md, "Test plan").
{ self }:
{ ... }:

{
  name = "chandlery-hytale-real";

  nodes.machine =
    { ... }:
    {
      imports = [ self.nixosModules.default ];
      virtualisation.memorySize = 6144;
      virtualisation.cores = 4;
      virtualisation.diskSize = 4096;

      users.users.dan = {
        isNormalUser = true;
        group = "users";
      };

      systemd.tmpfiles.rules = [
        "d /data/servers/hytale-eldermarch 0755 dan users -"
        "f+ /data/servers/hytale-eldermarch/machine-id 0444 dan users - 0123456789abcdef0123456789abcdef"
      ];

      services.chandlery.servers.eldermarch = {
        game = "hytale";
        user = "dan";
        group = "users";
        dataDir = "/data/servers/hytale-eldermarch";
        port = 5521;
        machineIdFile = "/data/servers/hytale-eldermarch/machine-id";
        extraArgs = [
          "--auth-mode"
          "offline"
        ];
      };
    };

  testScript = ''
    def journal():
        return machine.succeed("journalctl -o cat -u chandlery-eldermarch.service")

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("chandlery-eldermarch.service")

    with subtest("ready on its boot line, bound to the port it is given"):
        status = machine.succeed("systemctl show -P StatusText chandlery-eldermarch.service")
        assert "Hytale Server Booted!" in status, status
        machine.succeed("ss -Huln | grep -q ':5521 '")
        machine.fail("ss -Huln | grep -q ':5520 '")

    with subtest("it finds its machine's identity in the per-server machine-id"):
        assert "Failed to get hardware UUID" not in journal()

    with subtest("the console reaches it"):
        machine.succeed("chandlery-console eldermarch /help")
        machine.wait_until_succeeds("journalctl -o cat -u chandlery-eldermarch.service | grep -qF '/whoami'")

    with subtest("stop types /stop, and it saves and exits cleanly"):
        machine.succeed("systemctl stop chandlery-eldermarch.service")
        log = journal()
        assert "Shutdown completed" in log, log
        assert machine.succeed("systemctl show -P Result chandlery-eldermarch.service").strip() == "success"
        machine.succeed("test -d /data/servers/hytale-eldermarch/universe")
  '';
}
