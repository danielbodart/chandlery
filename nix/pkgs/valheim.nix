# Valheim Dedicated Server as a Chandlery package: the image's filesystem minus
# Debian (docs/nix.md, "The package layout").
#
# Valheim's depot needs a licensed Steam account, so nothing here fetches from
# Steam: the game is the published image's /opt/valheim, its layers fetched from
# GHCR by the digests nix/versions.json pins (nix/oci.nix) — what the image's
# own build downloaded with the operator's account — and autoPatchelf'd against
# the libraries the image installs from Debian. It is its own derivation, so a
# change to the scripts around it rebuilds this small package and not 1.9 GB of
# game. The scripts are images/valheim/'s, unchanged, with the environment the
# image's ENV gives them.
{
  lib,
  stdenv,
  stdenvNoCC,
  makeWrapper,
  callPackage,
  coreutils,
  findutils,
  gnugrep,
  zlib,
  libpulseaudio,
  chandlery-a2s ? callPackage ./chandlery-a2s.nix { },
  # A game tree to package instead of the image's /opt/valheim, and its
  # version: how the VM tests run the real adapter around a fake server.
  game ? null,
  version ? null,
}:

let
  pin = (lib.importJSON ../versions.json).valheim;
  fake = game != null;
  # The line it prints when its world is loaded and its socket open (1.0.20,
  # nix/tests/valheim-real.nix): Steam's, or PlayFab's under -crossplay. Not
  # "Game server connected", which waits on Steam's backend and may never come.
  readyPattern = "Opened (Steam|PlayFab) server";
  tree =
    if fake then
      game
    else
      "${
        callPackage ../oci.nix { } {
          pname = "chandlery-valheim-game";
          inherit (pin) version image layers;
          subtree = "opt/valheim";
          # What its ELF files link: libstdc++/libgcc_s and zlib, as any Unity
          # player's do, and PulseAudio, which PlayFab Party (crossplay) links
          # and the image installs (libpulse0) for it.
          elfDeps = [
            stdenv.cc.cc.lib
            zlib
            libpulseaudio
          ];
          # Unity's Wayland window decorations, never loaded by a headless server.
          elfIgnoreMissing = [
            "libwayland-client.so.0"
            "libwayland-cursor.so.0"
            "libcairo.so.2"
            "libpango-1.0.so.0"
            "libpangocairo-1.0.so.0"
          ];
        }
      }/opt/valheim";
  # The image's libatomic1, which nothing in the game links but which it
  # installs (after Iron Gate's own image): on the library path, for a dlopen.
  runtimeLibs = lib.makeLibraryPath [ stdenv.cc.cc.lib ];
in
stdenvNoCC.mkDerivation {
  pname = "chandlery-valheim";
  version = if version != null then version else pin.version;

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/opt
    ln -s ${tree} $out/opt/valheim
    test -x $out/opt/valheim/valheim_server.x86_64

    install -Dm0755 ${../../images/valheim/run} $out/bin/valheim-server
    ln -s valheim-server $out/bin/chandlery-server
    install -Dm0755 ${../../images/valheim/prepare} $out/lib/chandlery/prepare
    install -Dm0755 ${../../images/valheim/health} $out/lib/chandlery/health
    install -Dm0755 ${../../images/valheim/game-version} $out/lib/chandlery/game-version
    # The image puts chandlery-a2s at /usr/local/bin; the package has its own.
    substituteInPlace $out/lib/chandlery/health \
      --replace-fail /usr/local/bin/chandlery-a2s ${lib.getExe chandlery-a2s}
    # No lib/chandlery/stop: images/valheim/stop-hook signals the server's PID,
    # which ExecStop cannot see under PrivatePIDs. The unit's KillSignal=SIGINT,
    # the signal Valheim saves on, reaches it instead (docs/nix.md, "Stop").
    patchShebangs $out/bin $out/lib/chandlery

    for f in $out/bin/valheim-server $out/lib/chandlery/{prepare,health,game-version}; do
      wrapProgram "$f" \
        --set VALHEIM_VERSION "$version" \
        --set VALHEIM_BUILD_ID ${lib.escapeShellArg (pin.buildId or "")} \
        --set VALHEIM_MANIFEST_GID ${lib.escapeShellArg (pin.manifestGid or "")} \
        --set VALHEIM_APP_ID 896660 \
        --set VALHEIM_DEPOT_ID 896661 \
        --prefix LD_LIBRARY_PATH : ${runtimeLibs} \
        --prefix PATH : ${
          lib.makeBinPath [
            coreutils
            findutils
            gnugrep
          ]
        }
    done

    cat > $out/lib/chandlery/game.env <<ENV
    GAME=valheim
    VALHEIM_VERSION=$version
    CHANDLERY_READY='${if readyPattern == null then "" else readyPattern}'
    CHANDLERY_STAGE=link
    ENV

    runHook postInstall
  '';

  passthru = {
    game = "valheim";
    inherit readyPattern chandlery-a2s;
  };

  meta = {
    description = "Valheim Dedicated Server, packaged for Chandlery's native units";
    homepage = "https://github.com/danielbodart/chandlery";
    license = if fake then lib.licenses.asl20 else lib.licenses.unfree;
    sourceProvenance = lib.optional (!fake) lib.sourceTypes.binaryNativeCode;
    platforms = [ "x86_64-linux" ];
    mainProgram = "valheim-server";
  };
}
