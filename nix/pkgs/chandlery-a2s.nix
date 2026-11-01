# chandlery-a2s: the Steam A2S_INFO query Valheim's health check makes
# (images/valheim/health). The image takes it from `mise run dist`, which runs
# its tests first; this builds it from the same source and runs them too.
{
  lib,
  # The Go mise.toml pins, by minor.
  buildGo127Module,
}:

buildGo127Module {
  pname = "chandlery-a2s";
  # A fixed version, not 0-unstable-<date> as elsewhere: a date moves with
  # every commit, and a moved version is a new store path that restarts every
  # game server running these tools, for commits that did not touch them.
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../../images/valheim/probe;
    fileset = lib.fileset.unions [
      ../../images/valheim/probe/go.mod
      ../../images/valheim/probe/main.go
      ../../images/valheim/probe/main_test.go
    ];
  };
  vendorHash = null;
  env.CGO_ENABLED = 0;

  # The module is named after its directory; the image calls it chandlery-a2s.
  postInstall = ''
    mv $out/bin/probe $out/bin/chandlery-a2s
  '';

  meta = {
    description = "Ask a Steam game server for its A2S_INFO: Valheim's health check";
    homepage = "https://github.com/danielbodart/chandlery";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux;
    mainProgram = "chandlery-a2s";
  };
}
