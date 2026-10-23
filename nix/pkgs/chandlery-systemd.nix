# The native tools (systemd/): what a unit runs before, beside and after the
# game. Small on purpose — this is in every server's confinement — so it
# carries no systemd: chandlery-console runs on the host and finds the host's
# journalctl.
{
  lib,
  buildGoModule,
  makeWrapper,
  coreutils,
  findutils,
  gawk,
  diffutils,
  flock,
  gnutar,
  gzip,
  zstd,
}:

buildGoModule {
  pname = "chandlery-systemd";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../systemd
      ../../images/base/console.sh
      ../../test/lib.sh
      ../../test/systemd_test.sh
    ];
  };
  modRoot = "systemd";
  vendorHash = null;
  env.CGO_ENABLED = 0;

  nativeBuildInputs = [ makeWrapper ];

  postInstall = ''
    install -Dm0755 $src/images/base/console.sh $out/libexec/chandlery/console
    for f in $src/systemd/bin/*; do
      install -Dm0755 "$f" "$out/bin/$(basename "$f")"
    done
    substituteInPlace $out/bin/chandlery-console --replace-fail @consoleSh@ $out/libexec/chandlery/console
    patchShebangs $out/bin $out/libexec
    for f in $out/bin/chandlery-{console,make-data-dir,prepare,set-property,stop}; do
      wrapProgram "$f" --prefix PATH : ${
        lib.makeBinPath [
          coreutils
          findutils
          gawk
          diffutils
          flock
        ]
      }:$out/bin
    done
    # Not run by any unit, so its tar and decompressors stay out of the
    # servers' confinement.
    wrapProgram $out/bin/chandlery-unpack --prefix PATH : ${
      lib.makeBinPath [
        coreutils
        findutils
        gnutar
        gzip
        zstd
      ]
    }
  '';

  # The shell half's tests, against what was just installed.
  doInstallCheck = true;
  nativeInstallCheckInputs = [
    flock
    gnutar
    gzip
  ];
  installCheckPhase = ''
    runHook preInstallCheck
    CHANDLERY_TOOLS=$out/bin CHANDLERY_CONSOLE_SH=$out/libexec/chandlery/console \
      sh $src/test/systemd_test.sh
    runHook postInstallCheck
  '';

  meta = {
    description = "Run Chandlery's game servers as confined native systemd services";
    homepage = "https://github.com/danielbodart/chandlery";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux;
  };
}
