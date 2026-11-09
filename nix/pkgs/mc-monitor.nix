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
  version = "1.19.0";

  src = fetchFromGitHub {
    owner = "itzg";
    repo = "mc-monitor";
    tag = finalAttrs.version;
    hash = "sha256-PMAOncg0qWX/JDK8E459+ctbQKz7VjRxOoPl8Fl8Y/g=";
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
