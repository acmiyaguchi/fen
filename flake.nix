{
  description = "fen: minimal Lua/Fennel coding agent";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachSystem [
      "x86_64-linux"
      "aarch64-linux"
      "armv7l-linux"
    ] (system:
      let
        pkgs = import nixpkgs { inherit system; };
        lib = pkgs.lib;
        fenLib = import ./nix/lib.nix { inherit lib; };
        version = self.shortRev or self.dirtyShortRev or "unknown";

        mkArtifacts = targetPkgs: targetSystem:
          import ./nix/artifacts.nix ({
            inherit pkgs targetPkgs version targetSystem;
          } // fenLib);

        native = mkArtifacts pkgs system;

        crossTargets = lib.optionalAttrs (system == "x86_64-linux") (let
          aarch64Pkgs = import nixpkgs {
            inherit system;
            crossSystem = lib.systems.examples.aarch64-multiplatform;
          };
          armv7Pkgs = import nixpkgs {
            inherit system;
            crossSystem = lib.systems.examples.armv7l-hf-multiplatform;
          };
        in {
          aarch64 = {
            pkgs = aarch64Pkgs;
            artifacts = mkArtifacts aarch64Pkgs "aarch64-linux";
            qemu = "qemu-aarch64";
          };
          armv7 = {
            pkgs = armv7Pkgs;
            artifacts = mkArtifacts armv7Pkgs "armv7l-linux";
            qemu = "qemu-arm";
          };
        });

        crossArtifacts = lib.optionalAttrs (system == "x86_64-linux") {
          dist-linux-aarch64 = crossTargets.aarch64.artifacts.dist;
          distTree-linux-aarch64 = crossTargets.aarch64.artifacts.distTree;
          fenSingle-linux-aarch64 = crossTargets.aarch64.artifacts.fenSingle;
          distScratchImage-linux-aarch64 = crossTargets.aarch64.artifacts.distScratchImage;
          dist-linux-armv7-gnueabihf = crossTargets.armv7.artifacts.dist;
          distTree-linux-armv7-gnueabihf = crossTargets.armv7.artifacts.distTree;
          fenSingle-linux-armv7-gnueabihf = crossTargets.armv7.artifacts.fenSingle;
          distScratchImage-linux-armv7-gnueabihf = crossTargets.armv7.artifacts.distScratchImage;
        };

        crossChecks = lib.optionalAttrs (system == "x86_64-linux") {
          qemuSmoke-linux-aarch64 = crossTargets.aarch64.artifacts.checks.qemuSmoke;
          singleSmoke-linux-aarch64 = crossTargets.aarch64.artifacts.checks.singleQemuSmoke;
          qemuSmoke-linux-armv7-gnueabihf = crossTargets.armv7.artifacts.checks.qemuSmoke;
          singleSmoke-linux-armv7-gnueabihf = crossTargets.armv7.artifacts.checks.singleQemuSmoke;
        };

        mkQemuApp = name: targetPkgs: artifacts: qemu: {
          type = "app";
          program = toString (pkgs.writeShellScript name ''
            set -eu
            tree=${artifacts.distTree}/opt/fen
            ld_interp=$(echo ${targetPkgs.stdenv.cc.bintools.dynamicLinker})
            export LUA_PATH="$tree/share/lua/5.4/?.lua;$tree/share/lua/5.4/?/init.lua;''${LUA_PATH:-;;}"
            export LUA_CPATH="$tree/lib/lua/5.4/?.so;''${LUA_CPATH:-;;}"
            exec ${pkgs.pkgsStatic.qemu-user}/bin/${qemu} \
              "$tree/lib/$(basename "$ld_interp")" \
              --library-path "$tree/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
              "$tree/libexec/lua" \
              "$tree/share/fen/bin/fen.lua" "$@"
          '');
        };

        crossApps = lib.optionalAttrs (system == "x86_64-linux") {
          fen-aarch64-qemu = mkQemuApp "fen-aarch64-qemu"
            crossTargets.aarch64.pkgs crossTargets.aarch64.artifacts crossTargets.aarch64.qemu;
          fen-armv7-qemu = mkQemuApp "fen-armv7-qemu"
            crossTargets.armv7.pkgs crossTargets.armv7.artifacts crossTargets.armv7.qemu;
        };
      in {
        packages = {
          default = native.package;
          fen = native.package;
          fenSingle = native.fenSingle;
          distTree = native.distTree;
          dist = native.dist;
          distScratchImage = native.distScratchImage;
        } // crossArtifacts;

        checks = {
          distSmoke = native.checks.distSmoke;
          fennelCheck = native.checks.fennelCheck;
          tests = native.checks.tests;
          singleSmoke = native.checks.singleSmoke;
          singleDevSmoke = native.checks.singleDevSmoke;
          singleExtRootSmoke = native.checks.singleExtRootSmoke;
          binFenDevSmoke = native.checks.binFenDevSmoke;
        } // crossChecks;

        apps = {
          default = flake-utils.lib.mkApp { drv = native.package; };

          loadDockerDev = {
            type = "app";
            program = toString (pkgs.writeShellScript "load-fen-docker-dev" ''
              set -eu
              img=$(docker load < ${native.distScratchImage} \
                | sed -n 's/Loaded image: //p' \
                | tail -1)
              docker tag "$img" fen:dev
              echo "loaded $img as fen:dev"
              echo "run with: docker run --rm fen:dev --help"
            '');
          };

          dockerSmoke = {
            type = "app";
            program = toString (pkgs.writeShellScript "fen-docker-smoke" ''
              set -eu
              img=$(docker load < ${native.distScratchImage} \
                | sed -n 's/Loaded image: //p' \
                | tail -1)
              docker tag "$img" fen:dev
              docker run --rm fen:dev --help
            '');
          };
        } // crossApps;

        devShells.default = native.devShell;
      });
}
