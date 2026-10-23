# itzg/mc-monitor: the RakNet unconnected-ping Bedrock's health check uses
# (images/bedrock/health). The image copies it out of itzg/mc-monitor:latest;
# here it is pinned.
{
  lib,
  # 1.18 wants Go 1.27, newer than nixpkgs' default.
  buildGo127Module,
  fetchFromGitHub,
}:

buildGo127Module (finalAttrs: {
  pname = "mc-monitor";
  version = "1.18.3";

  src = fetchFromGitHub {
    owner = "itzg";
    repo = "mc-monitor";
    tag = finalAttrs.version;
    hash = "sha256-0BOoCgIP/T0uFZza3VBjS5FxlGQQVx1JIZiRN1Aemp4=";
  };

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
