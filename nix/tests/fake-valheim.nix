# A Valheim-shaped package: the real adapter and wrappers (nix/pkgs/valheim.nix)
# around test/fixtures/fake-valheim — the fake the Docker adapter tests use,
# which answers A2S, prints its arguments, and saves only on SIGINT — and a stub
# steamclient.so, where the real build puts them.
{ pkgs }:

let
  server = pkgs.buildGoModule {
    pname = "fake-valheim";
    version = "0.0.1";
    src = ../../test/fixtures/fake-valheim;
    vendorHash = null;
    env.CGO_ENABLED = 0;
  };
  tree = pkgs.runCommand "fake-valheim-tree" { } ''
    mkdir -p $out
    install -m0755 ${server}/bin/fake-valheim $out/valheim_server.x86_64
    : > $out/steamclient.so
  '';
in
pkgs.callPackage ../pkgs/valheim.nix {
  game = tree;
  version = "0.0.1-fake";
}
