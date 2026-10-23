# The real Valheim server, from the published image's layers and
# autoPatchelf'd, in the confined unit the module renders: it boots (offline:
# the VM has no internet, so Steam's backend never answers), generates its world
# and is ready on its own line, binds the port it is given and the query port
# after it, and a stop — SIGINT, no hook — saves the world and exits cleanly; a
# restart loads that world again. Heavy — 1.9 GB of layers, a Unity server — so
# it is not in `checks`: `nix build .#heavyChecks.valheim-vm` (docs/nix.md,
# "Test plan").
{ self }:
{ ... }:

{
  name = "chandlery-valheim-real";

  nodes.machine =
    { ... }:
    {
      imports = [ self.nixosModules.default ];
      virtualisation.memorySize = 4096;
      virtualisation.cores = 4;
      virtualisation.diskSize = 4096;

      users.users.dan = {
        isNormalUser = true;
        group = "users";
      };

      environment.etc."valheim-harbour.env" = {
        text = "VALHEIM_PASSWORD=hunter22\n";
        mode = "0400";
      };

      services.chandlery.servers.harbour = {
        game = "valheim";
        user = "dan";
        group = "users";
        dataDir = "/data/servers/valheim-harbour";
        port = 2470;
        environmentFiles = [ "/etc/valheim-harbour.env" ];
        extraArgs = [
          "-name"
          "Harbour"
          "-world"
          "Longship"
          "-public"
          "0"
        ];
      };
    };

  testScript = ''
    def journal():
        return machine.succeed("journalctl -o cat -u chandlery-harbour.service")

    def show(prop):
        return machine.succeed(f"systemctl show -P {prop} chandlery-harbour.service").strip()

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("chandlery-harbour.service", timeout=900)

    with subtest("ready on its own line, with its world generated"):
        assert show("Type") == "notify"
        assert "Opened Steam server" in show("StatusText"), show("StatusText")
        log = journal()
        assert "Valheim version: l-" in log, log
        assert "Setting -savedir to: /data" in log, log

    with subtest("bound to the port it is given, and the query port after it"):
        machine.wait_until_succeeds("ss -Huln | grep -q ':2470 '", timeout=60)
        machine.succeed("ss -Huln | grep -q ':2471 '")
        machine.fail("ss -Huln | grep -q ':2456 '")

    with subtest("a stop is SIGINT, and it saves the world and exits cleanly"):
        machine.succeed("systemctl stop chandlery-harbour.service")
        log = journal()
        assert "World save (5/5) done" in log, log
        assert show("Result") == "success", show("Result")
        # 1.0's save format: a directory of chunks per world.
        machine.succeed("ls /data/servers/valheim-harbour/worlds_local/Longship/_main.*.ok")
        machine.succeed("ls /data/servers/valheim-harbour/worlds_local/Longship/*.chunk")

    with subtest("a restart loads the world it saved"):
        machine.succeed("systemctl start chandlery-harbour.service")
        machine.wait_until_succeeds("journalctl -o cat -u chandlery-harbour.service | grep -q 'ZNet.LoadWorld: Longship'", timeout=300)
        machine.succeed("systemctl stop chandlery-harbour.service")
        assert show("Result") == "success"
  '';
}
