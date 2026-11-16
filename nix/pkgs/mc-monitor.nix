# itzg/mc-monitor: the RakNet unconnected-ping Bedrock's health check uses
# (images/bedrock/health). The image copies it out of itzg/mc-monitor at this
# tag, by digest; here it is built from the same tag.
{
  lib,
  # 1.18 wants Go 1.27, newer than nixpkgs' default; and it is the Go
  # mise.toml pins.
  buildGo127Module,
  fetchFromGitHub,
}:

buildGo127Module (finalAttrs: {
  pname = "mc-monitor";
  version = "1.21.0";

  src = fetchFromGitHub {
    owner = "itzg";
    repo = "mc-monitor";
    tag = finalAttrs.version;
    hash = "sha256-L8jMv0NSzzhh0jZZs1e0/8HezGASAEpuIRqaNnFRPqE=";
  };

  # Upstream's go.mod names the newest Go patch release (go 1.27.4 at 1.21.0),
  # but a host that follows its own nixpkgs (nix-config does) may be a patch
  # behind, and GOTOOLCHAIN=local then refuses to build. Any 1.27 builds it,
  # so the directive is relaxed to the minor version rather than holding the
  # server back until its nixpkgs catches up.
  postPatch = ''
    sed -i -E 's/^go 1\.27\.[0-9]+$/go 1.27/' go.mod
  '';

  vendorHash = "sha256-eH+QGA2lcNGy9RngZr7HYYRP6pcUHJdmKm7SmNUKlJk=";
  env.CGO_ENABLED = 0;
  ldflags = [
    "-s"
    "-w"
    "-X main.version=${finalAttrs.version}"
  ];
  doCheck = false;

  meta = {
    description = "Monitor the status of Minecraft servers";
    homepage = "https://github.com/itzg/mc-monitor";
    license = lib.licenses.mit;
    mainProgram = "mc-monitor";
  };
})
