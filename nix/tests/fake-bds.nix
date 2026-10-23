# A Bedrock-shaped package around ./fake-bds: the real adapter and wrappers
# (nix/pkgs/bedrock.nix), a fake game tree.
{
  pkgs,
  version ? "0.0.1",
}:

let
  tree = pkgs.runCommand "fake-bds-tree" { } ''
    mkdir -p $out
    install -m0755 ${./fake-bds} $out/bedrock_server
    patchShebangs $out/bedrock_server
    sed -i '2i PATH=${
      pkgs.lib.makeBinPath [
        pkgs.coreutils
        pkgs.gnused
      ]
    }' $out/bedrock_server
    printf '%s\n' 'server-name=Dedicated Server' 'server-port=19132' 'server-portv6=19133' 'level-name=Bedrock level' > $out/server.properties
    echo '[]' > $out/allowlist.json
    echo '[]' > $out/permissions.json
  '';
in
pkgs.callPackage ../pkgs/bedrock.nix {
  game = tree;
  inherit version;
}
