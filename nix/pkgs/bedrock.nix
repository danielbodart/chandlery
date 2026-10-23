# Minecraft Bedrock Dedicated Server as a Chandlery package: the image's
# filesystem minus Debian (docs/nix.md, "The package layout").
#
# BDS comes from Mojang's zip, pinned by nix/versions.json to the same sha256
# the image's build verifies, unzipped as images/bedrock/fetch does and
# autoPatchelf'd. The scripts around it are images/bedrock/'s, unchanged, with
# the environment the image's ENV gives them.
{
  lib,
  stdenv,
  fetchurl,
  unzip,
  autoPatchelfHook,
  makeWrapper,
  coreutils,
  gnused,
  callPackage,
  mc-monitor ? callPackage ./mc-monitor.nix { },
  # A game tree to package instead of Mojang's zip, and its version: how the VM
  # tests run the real adapter around a fake BDS.
  game ? null,
  version ? null,
}:

let
  pin = (lib.importJSON ../versions.json).bedrock;
  fake = game != null;
  readyPattern = "Server started\\.";
in
stdenv.mkDerivation {
  pname = "chandlery-bedrock";
  version = if version != null then version else pin.version;

  src =
    if fake then
      game
    else
      fetchurl {
        url = "https://www.minecraft.net/bedrockdedicatedserver/bin-linux/bedrock-server-${pin.version}.zip";
        inherit (pin) sha256;
        # Mojang's CDN kills the HTTP/2 stream for a User-Agent with spaces in
        # it, fetchurl's own included; a plain token gets a clean 200
        # (images/bedrock/fetch).
        curlOptsList = [
          "--user-agent"
          "chandlery/bedrock"
        ];
      };

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  # 100 MB of someone else's binary: patch its interpreter and rpath, nothing more.
  dontStrip = true;

  nativeBuildInputs = [
    unzip
    autoPatchelfHook
    makeWrapper
  ];
  buildInputs = [ stdenv.cc.cc.lib ];

  installPhase = ''
    runHook preInstall

    game=$out/opt/bedrock
    mkdir -p $game
    ${if fake then "cp -r $src/. $game" else "unzip -q $src -d $game"}
    chmod -R u+w $game
    # The same build leftovers images/bedrock/fetch drops.
    rm -f $game/libMinecraft.Server.Lib.a $game/bedrock_server_debug_symbols.debug
    test -x $game/bedrock_server

    install -Dm0755 ${../../images/bedrock/run} $out/bin/bedrock-server
    ln -s bedrock-server $out/bin/chandlery-server
    install -Dm0755 ${../../images/bedrock/prepare} $out/lib/chandlery/prepare
    install -Dm0755 ${../../images/bedrock/stop-hook} $out/lib/chandlery/stop
    install -Dm0755 ${../../images/bedrock/health} $out/lib/chandlery/health
    # The image puts mc-monitor at /usr/local/bin; the package has its own.
    substituteInPlace $out/lib/chandlery/health \
      --replace-fail /usr/local/bin/mc-monitor ${lib.getExe mc-monitor}
    # The stop hook types at the console with the image's own console.sh.
    install -Dm0755 ${../../images/base/console.sh} $out/libexec/chandlery/chandlery-console
    patchShebangs $out/bin $out/lib/chandlery $out/libexec

    for f in $out/bin/bedrock-server $out/lib/chandlery/{prepare,stop,health}; do
      wrapProgram "$f" \
        --set BEDROCK_VERSION "$version" \
        --prefix PATH : ${
          lib.makeBinPath [
            coreutils
            gnused
          ]
        }:$out/libexec/chandlery
    done

    cat > $out/lib/chandlery/game.env <<ENV
    GAME=bedrock
    BEDROCK_VERSION=$version
    CHANDLERY_READY='${readyPattern}'
    CHANDLERY_STAGE=copy-links
    CHANDLERY_PROPERTIES=/data/server.properties
    ENV

    runHook postInstall
  '';

  passthru = {
    game = "bedrock";
    inherit readyPattern mc-monitor;
  };

  meta = {
    description = "Minecraft Bedrock Dedicated Server, packaged for Chandlery's native units";
    homepage = "https://github.com/danielbodart/chandlery";
    license = if fake then lib.licenses.asl20 else lib.licenses.unfree;
    sourceProvenance = lib.optional (!fake) lib.sourceTypes.binaryNativeCode;
    platforms = [ "x86_64-linux" ];
    mainProgram = "bedrock-server";
  };
}
