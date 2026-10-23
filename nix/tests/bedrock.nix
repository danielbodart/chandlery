# Real BDS, end to end, in the confined unit the module renders: ready on
# "Server started.", the console reaches it, the ports land in
# server.properties beside the operator's own keys and BDS binds them, a stop
# saves and exits cleanly, and a restart reopens the same world.
#
# The VM has no internet, and BDS in online mode waits a minute for Minecraft
# services, gives up and asks itself to stop (then hangs: seen in this test).
# So the test plays the operator who already has a server.properties — the
# stock one with online-mode=false (and so allow-list=false, which BDS insists
# on without online authentication) and a key of their own. And RakNet, not
# 1.26's default NetherNet, whose sockets depend on Microsoft's signalling
# service (offline, it bound neither port on one start of two); RakNet binds
# server-port and server-portv6 deterministically, which is what this test is
# about. Without LAN visibility, which would bind 19132/19133 whatever
# server-port says. (BDS 1.26.52 then warns that NetherNet is the only
# supported transport, and gives mc-monitor's RakNet ping an empty response,
# so images/bedrock/health cannot be checked here.) — which is also the
# case that matters: the unit must set its two ports and leave the rest alone.
{ self }:
{ lib, ... }:

{
  name = "chandlery-bedrock";

  nodes.machine =
    { ... }:
    {
      imports = [ self.nixosModules.default ];
      virtualisation.memorySize = 2048;
      virtualisation.cores = 2;
      virtualisation.diskSize = 2048;

      users.users.dan = {
        isNormalUser = true;
        group = "users";
      };

      services.chandlery.servers.wrlin = {
        game = "bedrock";
        user = "dan";
        group = "users";
        dataDir = "/data/servers/wrlin";
        port = 19142;
        environment.TZ = "Europe/London";
      };

      # Started by the test, once the operator's config is in place.
      systemd.services.chandlery-wrlin.wantedBy = lib.mkForce [ ];
    };

  testScript =
    { nodes, ... }:
    let
      bds = nodes.machine.services.chandlery.servers.wrlin.package;
    in
    ''
      def journal():
          return machine.succeed("journalctl -o cat -u chandlery-wrlin.service")

      def wait_in_journal(text, timeout=120):
          machine.wait_until_succeeds(f"journalctl -o cat -u chandlery-wrlin.service | grep -qF '{text}'", timeout=timeout)

      machine.wait_for_unit("multi-user.target")
      machine.succeed(
          "install -d -o dan -g users /data/servers/wrlin",
          "sed -e 's/^online-mode=.*/online-mode=false/' -e 's/^allow-list=.*/allow-list=false/' -e 's/^transport=.*/transport=raknet/' -e 's/^enable-lan-visibility=.*/enable-lan-visibility=false/' ${bds}/opt/bedrock/server.properties > /data/servers/wrlin/server.properties",
          "echo 'my-own-key=kept' >> /data/servers/wrlin/server.properties",
          "chown dan:users /data/servers/wrlin/server.properties",
      )
      machine.succeed("systemctl start chandlery-wrlin.service")
      machine.wait_for_unit("chandlery-wrlin.service", timeout=600)

      with subtest("ready means BDS said so"):
          assert "Server started." in journal()
          status = machine.succeed("systemctl show -P StatusText chandlery-wrlin.service")
          assert "Server started." in status, status

      with subtest("the unit's ports are in server.properties, and BDS binds them"):
          props = machine.succeed("cat /data/servers/wrlin/server.properties")
          assert "server-port=19142\n" in props and "server-portv6=19143\n" in props, props
          assert "online-mode=false\n" in props and "my-own-key=kept\n" in props, props
          assert "server-port=19132" not in props, props
          assert "IPv4 supported, port: 19142" in journal()
          assert "IPv6 supported, port: 19143" in journal()
          machine.wait_until_succeeds("ss -Hulpn 'sport = 19142' | grep -q bedrock_server")
          machine.wait_until_succeeds("ss -Hulpn 'sport = 19143' | grep -q bedrock_server")
          machine.fail("ss -Hulpn 'sport = 19132' | grep -q .")
          machine.succeed("stat -c %U /data/servers/wrlin/server.properties | grep -qx dan")

      with subtest("the console reaches BDS"):
          machine.succeed("chandlery-console wrlin list")
          wait_in_journal("players online")

      with subtest("BDS made its world under dataDir, through the staged links"):
          machine.wait_until_succeeds("test -d '/data/servers/wrlin/worlds/Bedrock level/db'")
          machine.succeed("touch '/data/servers/wrlin/worlds/Bedrock level/marker'")

      with subtest("stop saves and exits cleanly"):
          machine.succeed("systemctl stop chandlery-wrlin.service")
          log = journal()
          assert "Quit correctly" in log, log
          assert machine.succeed("systemctl show -P Result chandlery-wrlin.service").strip() == "success"
          assert machine.succeed("systemctl show -P ExecMainStatus chandlery-wrlin.service").strip() == "0"

      with subtest("a restart reopens the same world, and keeps the operator's keys"):
          machine.succeed("systemctl start chandlery-wrlin.service")
          machine.succeed("test -e '/data/servers/wrlin/worlds/Bedrock level/marker'")
          assert machine.succeed("ls /data/servers/wrlin/worlds").split("\n")[:-1] == ["Bedrock level"]
          assert "my-own-key=kept" in machine.succeed("cat /data/servers/wrlin/server.properties")
          machine.wait_until_succeeds("ss -Hulpn 'sport = 19142' | grep -q bedrock_server")

      with subtest("its exposure"):
          print(machine.succeed("systemd-analyze security --no-pager chandlery-wrlin.service | tail -1"))
    '';
}
