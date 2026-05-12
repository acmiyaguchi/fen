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
        envVersion = builtins.getEnv "FEN_VERSION";
        version = if envVersion != "" then envVersion else self.shortRev or self.dirtyShortRev or "unknown";
        versionInfo = {
          version = version;
          gitRev = self.rev or self.dirtyRev or "";
          gitShortRev = self.shortRev or self.dirtyShortRev or "";
          dirty = (self ? dirtyRev) || (self ? dirtyShortRev);
          source = "nix";
          lastModified = self.lastModifiedDate or "";
          buildSystem = system;
        };

        mkArtifacts = targetPkgs: targetSystem: opts:
          import ./nix/artifacts.nix ({
            inherit pkgs targetPkgs version versionInfo targetSystem;
          } // fenLib // opts);

        native = mkArtifacts pkgs system (lib.optionalAttrs (system == "armv7l-linux") {
          # Keep ARMv7 on the Nixpkgs glibc toolchain until the Zig/glibc
          # 2.17 build passes QEMU smoke.
          glibcFloorVersion = null;
        });
        nativeStatic = mkArtifacts pkgs.pkgsStatic system { static = true; };

        crossTargets = lib.optionalAttrs (system == "x86_64-linux") (let
          aarch64Pkgs = import nixpkgs {
            inherit system;
            crossSystem = lib.systems.examples.aarch64-multiplatform;
          };
          armv7Pkgs = import nixpkgs {
            inherit system;
            crossSystem = lib.systems.examples.armv7l-hf-multiplatform;
          };
          aarch64MuslPkgs = import nixpkgs {
            inherit system;
            crossSystem = lib.systems.examples.aarch64-multiplatform-musl;
          };
          armv7MuslPkgs = import nixpkgs {
            inherit system;
            crossSystem = { config = "armv7l-unknown-linux-musleabihf"; };
          };
        in {
          aarch64 = {
            pkgs = aarch64Pkgs;
            artifacts = mkArtifacts aarch64Pkgs "aarch64-linux" {};
            qemu = "qemu-aarch64";
          };
          armv7 = {
            pkgs = armv7Pkgs;
            # Keep ARMv7 on the Nixpkgs glibc toolchain until the Zig/glibc
            # 2.17 build passes QEMU smoke.
            artifacts = mkArtifacts armv7Pkgs "armv7l-linux" { glibcFloorVersion = null; };
            qemu = "qemu-arm";
          };
          aarch64Static = {
            pkgs = aarch64MuslPkgs.pkgsStatic;
            artifacts = mkArtifacts aarch64MuslPkgs.pkgsStatic "aarch64-linux" { static = true; };
            qemu = "qemu-aarch64";
          };
          armv7Static = {
            pkgs = armv7MuslPkgs.pkgsStatic;
            artifacts = mkArtifacts armv7MuslPkgs.pkgsStatic "armv7l-linux" { static = true; };
            qemu = "qemu-arm";
          };
        });

        crossArtifacts = lib.optionalAttrs (system == "x86_64-linux") {
          fen-linux-aarch64 = crossTargets.aarch64.artifacts.fenBinary;
          scratchImage-linux-aarch64 = crossTargets.aarch64.artifacts.scratchImage;
          fen-linux-armv7-gnueabihf = crossTargets.armv7.artifacts.fenBinary;
          scratchImage-linux-armv7-gnueabihf = crossTargets.armv7.artifacts.scratchImage;
          fen-linux-aarch64-musl-static = crossTargets.aarch64Static.artifacts.fenBinary;
          fen-linux-armv7-musleabihf-static = crossTargets.armv7Static.artifacts.fenBinary;
        };

        crossChecks = lib.optionalAttrs (system == "x86_64-linux") {
          fenSmoke-linux-aarch64 = crossTargets.aarch64.artifacts.checks.fenQemuSmoke;
          fenNoStoreRefs-linux-aarch64 = crossTargets.aarch64.artifacts.checks.fenNoStoreRefs;
          fenDynamicDeps-linux-aarch64 = crossTargets.aarch64.artifacts.checks.fenDynamicDeps;
          fenSmoke-linux-armv7-gnueabihf = crossTargets.armv7.artifacts.checks.fenQemuSmoke;
          fenNoStoreRefs-linux-armv7-gnueabihf = crossTargets.armv7.artifacts.checks.fenNoStoreRefs;
          fenDynamicDeps-linux-armv7-gnueabihf = crossTargets.armv7.artifacts.checks.fenDynamicDeps;
          fenSmoke-linux-aarch64-musl-static = crossTargets.aarch64Static.artifacts.checks.fenQemuSmoke;
          fenNoStoreRefs-linux-aarch64-musl-static = crossTargets.aarch64Static.artifacts.checks.fenNoStoreRefs;
          fenDynamicDeps-linux-aarch64-musl-static = crossTargets.aarch64Static.artifacts.checks.fenDynamicDeps;
          fenSmoke-linux-armv7-musleabihf-static = crossTargets.armv7Static.artifacts.checks.fenQemuSmoke;
          fenNoStoreRefs-linux-armv7-musleabihf-static = crossTargets.armv7Static.artifacts.checks.fenNoStoreRefs;
          fenDynamicDeps-linux-armv7-musleabihf-static = crossTargets.armv7Static.artifacts.checks.fenDynamicDeps;
        };

        mkQemuApp = name: description: targetPkgs: artifacts: qemu: {
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
          meta.description = description;
        };

        crossApps = lib.optionalAttrs (system == "x86_64-linux") {
          fen-aarch64-qemu = mkQemuApp "fen-aarch64-qemu"
            "Run the aarch64 fen binary under qemu"
            crossTargets.aarch64.pkgs crossTargets.aarch64.artifacts crossTargets.aarch64.qemu;
          fen-armv7-qemu = mkQemuApp "fen-armv7-qemu"
            "Run the armv7 fen binary under qemu"
            crossTargets.armv7.pkgs crossTargets.armv7.artifacts crossTargets.armv7.qemu;
        };
      in {
        packages = {
          default = native.fenBinary;
          fen = native.fenBinary;
          fenSingleStatic = nativeStatic.fenBinary;
          scratchImage = native.scratchImage;
        } // crossArtifacts;

        checks = {
          fennelCheck = native.checks.fennelCheck;
          docs = native.checks.docs;
          tests = native.checks.tests;
          fenSmoke = native.checks.fenSmoke;
          fenMockProviderSmoke = native.checks.fenMockProviderSmoke;
          fenOverlaySmoke = native.checks.fenOverlaySmoke;
          fenExtBuildSmoke = native.checks.fenExtBuildSmoke;
          fenNoStoreRefs = native.checks.fenNoStoreRefs;
          fenDynamicDeps = native.checks.fenDynamicDeps;
          singleStaticSmoke = nativeStatic.checks.fenSmoke;
          singleStaticNativeSmoke = nativeStatic.checks.fenOverlaySmoke;
          singleStaticNoStoreRefs = nativeStatic.checks.fenNoStoreRefs;
          singleStaticNoDynamicDeps = nativeStatic.checks.fenDynamicDeps;
        } // crossChecks;

        apps = {
          default = (flake-utils.lib.mkApp { drv = native.fenBinary; }) // {
            meta.description = "Run fen";
          };

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
            meta.description = "Load the fen scratch Docker image and tag it as fen:dev";
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
            meta.description = "Smoke-test the fen scratch Docker image";
          };
        } // crossApps;

        devShells.default = native.devShell;
      });
}
