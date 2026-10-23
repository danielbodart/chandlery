# A Hytale-shaped package: the real adapter and wrappers (nix/pkgs/hytale.nix)
# around a stub jar and assets, run on test/fixtures/fake-hytale/java — the
# fake the Docker adapter tests use — in place of a JRE.
{ pkgs }:

let
  tree = pkgs.runCommand "fake-hytale-tree" { } ''
    mkdir -p $out/Server
    : > $out/Server/HytaleServer.jar
    : > $out/Assets.zip
  '';
  java = pkgs.runCommand "fake-java" { } ''
    install -Dm0755 ${../../test/fixtures/fake-hytale/java} $out/bin/java
    patchShebangs $out/bin/java
  '';
in
pkgs.callPackage ../pkgs/hytale.nix {
  game = tree;
  inherit java;
  version = "0.0.1-fake";
}
