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
          fen-linux-aarch64 = crossTargets.aarch64.artifacts.fenBinary;
          scratchImage-linux-aarch64 = crossTargets.aarch64.artifacts.scratchImage;
          fen-linux-armv7-gnueabihf = crossTargets.armv7.artifacts.fenBinary;
          scratchImage-linux-armv7-gnueabihf = crossTargets.armv7.artifacts.scratchImage;
        };

        crossChecks = lib.optionalAttrs (system == "x86_64-linux") {
          fenSmoke-linux-aarch64 = crossTargets.aarch64.artifacts.checks.fenQemuSmoke;
          fenSmoke-linux-armv7-gnueabihf = crossTargets.armv7.artifacts.checks.fenQemuSmoke;
        };

        mkQemuApp = name: targetPkgs: artifacts: qemu: {
          type = "app";
          program = toString (pkgs.writeShellScript name ''
            set -eu
            target_ld=$(echo ${targetPkgs.stdenv.cc.bintools.dynamicLinker})
            target_lib_path=${targetPkgs.glibc}/lib
            exec ${pkgs.pkgsStatic.qemu-user}/bin/${qemu} \
              "$target_ld" --argv0 ${artifacts.fenBinary}/bin/fen \
              --library-path "$target_lib_path''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
              ${artifacts.fenBinary}/bin/fen "$@"
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
          default = native.fenBinary;
          fen = native.fenBinary;
          scratchImage = native.scratchImage;
        } // crossArtifacts;

        checks = {
          fennelCheck = native.checks.fennelCheck;
          tests = native.checks.tests;
          fenSmoke = native.checks.fenSmoke;
          fenDevSmoke = native.checks.fenDevSmoke;
          fenExtRootSmoke = native.checks.fenExtRootSmoke;
          fenNativeSmoke = native.checks.fenNativeSmoke;
          fenExtBuildSmoke = native.checks.fenExtBuildSmoke;
          fenNoStoreRefs = native.checks.fenNoStoreRefs;
          fenDynamicDeps = native.checks.fenDynamicDeps;
          binFenDevSmoke = native.checks.binFenDevSmoke;
        } // crossChecks;

        apps = {
          default = flake-utils.lib.mkApp { drv = native.fenBinary; };

          loadDockerDev = {
            type = "app";
            program = toString (pkgs.writeShellScript "load-fen-docker-dev" ''
              set -eu
              img=$(docker load < ${native.scratchImage} \
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
              img=$(docker load < ${native.scratchImage} \
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
