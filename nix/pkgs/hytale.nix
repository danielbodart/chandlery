# Hytale Dedicated Server as a Chandlery package: the image's filesystem minus
# Debian (docs/nix.md, "The package layout").
#
# Hytale's files are OAuth-gated, so nothing here fetches from Hytale: the game
# is the published image's /opt/hytale, its layers fetched from GHCR by the
# digests nix/versions.json pins (nix/oci.nix) — what the image's own build
# fetched and verified. It is its own derivation, so a change to the scripts
# around it rebuilds this small package and not 3.4 GB of assets. The scripts
# are images/hytale/'s, unchanged, with the environment the image's ENV gives
# them and the JRE the image pins.
{
  lib,
  stdenvNoCC,
  makeWrapper,
  callPackage,
  temurin-jre-bin-25,
  coreutils,
  findutils,
  gnused,
  curl,
  # A Java to run it on instead of the image's Temurin 25: the VM tests' fake.
  # (Not `jre ? …`: callPackage would fill that with nixpkgs' default JRE.)
  java ? null,
  # A game tree to package instead of the image's /opt/hytale, and its version:
  # how the VM tests run the real adapter around a fake server.
  game ? null,
  version ? null,
}:

let
  pin = (lib.importJSON ../versions.json).hytale;
  fake = game != null;
  jre = if java != null then java else temurin-jre-bin-25;
  # The line the server prints once it listens and its universe is loaded
  # (0.7.4, in nix/tests/hytale-real.nix).
  readyPattern = "Hytale Server Booted!";
  tree =
    if fake then
      game
    else
      "${
        callPackage ../oci.nix { } {
          pname = "chandlery-hytale-game";
          inherit (pin) version image layers;
          subtree = "opt/hytale";
        }
      }/opt/hytale";
in
stdenvNoCC.mkDerivation {
  pname = "chandlery-hytale";
  version = if version != null then version else pin.version;

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/opt
    ln -s ${tree} $out/opt/hytale
    test -f $out/opt/hytale/Server/HytaleServer.jar

    install -Dm0755 ${../../images/hytale/run} $out/bin/hytale-server
    ln -s hytale-server $out/bin/chandlery-server
    install -Dm0755 ${../../images/hytale/prepare} $out/lib/chandlery/prepare
    install -Dm0755 ${../../images/hytale/stop-hook} $out/lib/chandlery/stop
    # The stop hook types /stop at the console with the image's own console.sh.
    install -Dm0755 ${../../images/base/console.sh} $out/libexec/chandlery/chandlery-console
    patchShebangs $out/bin $out/lib/chandlery $out/libexec

    for f in $out/bin/hytale-server $out/lib/chandlery/{prepare,stop}; do
      wrapProgram "$f" \
        --set HYTALE_VERSION "$version" \
        --set HYTALE_PATCHLINE release \
        --set HYTALE_DISABLE_UPDATES 1 \
        --set JAVA_HOME ${jre} \
        --prefix PATH : ${
          lib.makeBinPath [
            jre
            coreutils
            findutils
            gnused
            curl
          ]
        }:$out/libexec/chandlery
    done

    cat > $out/lib/chandlery/game.env <<ENV
    GAME=hytale
    HYTALE_VERSION=$version
    CHANDLERY_READY='${if readyPattern == null then "" else readyPattern}'
    CHANDLERY_STAGE=link
    ENV

    runHook postInstall
  '';

  passthru = {
    game = "hytale";
    inherit readyPattern jre;
  };

  meta = {
    description = "Hytale Dedicated Server, packaged for Chandlery's native units";
    homepage = "https://github.com/danielbodart/chandlery";
    license = if fake then lib.licenses.asl20 else lib.licenses.unfree;
    sourceProvenance = lib.optional (!fake) lib.sourceTypes.binaryBytecode;
    platforms = [ "x86_64-linux" ];
    mainProgram = "hytale-server";
  };
}
