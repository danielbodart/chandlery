{
  description = "Chandlery: game servers as confined native systemd services (and, alongside, the Docker images)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      # The games are x86_64-only (BDS and the published images have no ARM
      # builds); the tools and the module are not.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      games = [
        "bedrock"
        "hytale"
        "valheim"
      ];
      forAll = f: lib.genAttrs systems (system: f system);
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ self.overlays.default ];
          # Exactly the games, so `nix build .#bedrock` needs no --impure.
          config.allowUnfreePredicate = p: lib.elem (lib.getName p) (map (g: "chandlery-${g}") games);
        };
    in
    {
      overlays.default = final: prev: {
        chandlery = {
          bedrock = final.callPackage ./nix/pkgs/bedrock.nix { };
          hytale = final.callPackage ./nix/pkgs/hytale.nix { };
          valheim = final.callPackage ./nix/pkgs/valheim.nix { };
          a2s = final.callPackage ./nix/pkgs/chandlery-a2s.nix { };
          mc-monitor = final.callPackage ./nix/pkgs/mc-monitor.nix { };
          systemd = final.callPackage ./nix/pkgs/chandlery-systemd.nix { };
        };
      };

      nixosModules.chandlery = ./nix/module.nix;
      nixosModules.default = self.nixosModules.chandlery;

      packages = forAll (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          chandlery-systemd = pkgs.chandlery.systemd;
          default = pkgs.chandlery.systemd;
        }
        // lib.optionalAttrs (system == "x86_64-linux") {
          inherit (pkgs.chandlery)
            bedrock
            hytale
            valheim
            mc-monitor
            ;
          chandlery-a2s = pkgs.chandlery.a2s;
        }
      );

      checks.x86_64-linux =
        let
          pkgs = pkgsFor "x86_64-linux";
          test = path: pkgs.testers.runNixOSTest (import path { inherit self; });
        in
        {
          inherit (self.packages.x86_64-linux)
            bedrock
            chandlery-systemd
            chandlery-a2s
            mc-monitor
            ;
          versions =
            pkgs.runCommand "chandlery-versions-test"
              {
                nativeBuildInputs = [
                  pkgs.jq
                  pkgs.curl
                ];
              }
              ''
                cp -r ${./test} test && cp -r ${./nix} nix && chmod -R u+w .
                patchShebangs nix/update-versions
                sh test/versions_test.sh
                touch $out
              '';
          module = test ./nix/tests/module.nix;
          bedrock-vm = test ./nix/tests/bedrock.nix;
          hytale-vm = test ./nix/tests/hytale.nix;
        };

      # Checks too heavy for every push (gigabytes of game, a 4 GB JVM): run by
      # hand, or by CI where the runner has the disk. nix build .#heavyChecks.<name>
      legacyPackages.x86_64-linux.heavyChecks =
        let
          pkgs = pkgsFor "x86_64-linux";
          test = path: pkgs.testers.runNixOSTest (import path { inherit self; });
        in
        {
          inherit (self.packages.x86_64-linux) hytale valheim;
          hytale-vm = test ./nix/tests/hytale-real.nix;
        };

      devShells = forAll (system: {
        default =
          let
            pkgs = pkgsFor system;
          in
          pkgs.mkShell {
            packages = with pkgs; [
              go
              jq
              curl
              shellcheck
              gnumake
              util-linux
            ];
          };
      });

      formatter = forAll (system: (pkgsFor system).nixfmt-tree);
    };
}
