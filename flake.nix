{
  description = "fen: minimal Lua/Fennel coding agent";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    # busted only: 25.11 ships busted 2.2.0, which lacks the
    # busted/modules/files/fennel loader the test harness drives via
    # `--loaders=lua,fennel`. We pull just that test-only tool from unstable
    # (2.3.0+, which ships the loader); nothing shipped in an artifact uses it.
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, flake-utils }:
    flake-utils.lib.eachSystem [
      "x86_64-linux"
      "aarch64-linux"
      "armv7l-linux"
    ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          # Override only busted (test-only) with unstable's 2.3.0, which ships
          # the fennel busted loader missing from 25.11's 2.2.0. busted is not in
          # checkPins and never enters a shipped artifact.
          overlays = [
            (_final: prev: {
              lua54Packages = prev.lua54Packages // {
                inherit (nixpkgs-unstable.legacyPackages.${system}.lua54Packages) busted;
              };
            })
          ];
        };
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

        # fen ships a single Linux runtime: the fully-static musl binary. The
        # source-level checks it carries (fennelCheck/docs/tests) run with the
        # dynamic build-host toolchain, so they need no separate artifact set.
        native = mkArtifacts pkgs.pkgsStatic system {};

        # The dev shell uses the dynamic build-host packages directly (native
        # compilers, curl, graphviz), not the static cross/runtime set.
        devShell = import ./nix/dev-shell.nix {
          targetPkgs = pkgs;
          lua = pkgs.lua5_4;
          devLuaPackages = with pkgs.lua54Packages; [ lua-cjson luasocket ];
          testRocks = with pkgs.lua54Packages; [ busted ];
        };

        # Guard the non-Nix build's pinned third-party versions against drift
        # from the canonical Nix sources. Pure eval, no network: read the pins
        # from the Makefile and compare to the same nixpkgs packages
        # nix/artifacts.nix builds against. `make check-pins` does the same from
        # a shell. See docs/distribution.md ("Building without Nix").
        checkPins = let
          makeLines = lib.splitString "\n" (builtins.readFile ./Makefile);
          pinOf = var: let
            prefix = "${var} := ";
            hits = builtins.filter (l: lib.hasPrefix prefix l) makeLines;
          in if hits == [] then throw "check-pins: ${var} not found in Makefile"
             else lib.removePrefix prefix (builtins.head hits);
          # nixpkgs lua-rock versions carry a -<rockrev> suffix (e.g. 1.6.1-1).
          stripRev = v: let m = builtins.match "(.*)-[0-9]+" v; in if m == null then v else builtins.head m;
          pins = [
            { label = "kubazip";       pinned = pinOf "KUBAZIP_VER"; nix = pkgs.kubazip.version; }
            { label = "lua-cjson";     pinned = pinOf "CJSON_VER";   nix = pkgs.lua54Packages.lua-cjson.version; }
            { label = "luafilesystem"; pinned = pinOf "LFS_VER";     nix = pkgs.lua54Packages.luafilesystem.version; }
            { label = "luasocket";     pinned = pinOf "LUASOCKET_VER"; nix = pkgs.lua54Packages.luasocket.version; }
            { label = "fennel";        pinned = pinOf "FENNEL_VER";  nix = pkgs.lua54Packages.fennel.version; }
            { label = "dkjson";        pinned = pinOf "DKJSON_VER";  nix = pkgs.lua54Packages.dkjson.version; }
            { label = "lua";           pinned = pinOf "LUA_VER";     nix = pkgs.lua5_4.version; }
          ];
          results = map (p: p // { got = stripRev p.nix; ok = p.pinned == stripRev p.nix; }) pins;
          report = lib.concatMapStringsSep "\n"
            (r: "  ${if r.ok then "ok   " else "DRIFT"} ${r.label}: pinned ${r.pinned}, nixpkgs ${r.got}") results;
          drift = builtins.filter (r: !r.ok) results;
        in if drift != []
           then throw "check-pins: Makefile pins drifted from flake nixpkgs:\n${report}\nUpdate the Makefile *_VER pins (and SHAs) to match, or accept the divergence."
           else pkgs.runCommand "fen-${version}-check-pins" {} ''
             printf '%s\n' 'check-pins: Makefile pins in sync with flake nixpkgs' > "$out"
             printf '%s\n' ${lib.escapeShellArg report} >> "$out"
           '';

        crossTargets = lib.optionalAttrs (system == "x86_64-linux") (let
          aarch64MuslPkgs = import nixpkgs {
            inherit system;
            crossSystem = lib.systems.examples.aarch64-multiplatform-musl;
          };
          armv7MuslPkgs = import nixpkgs {
            inherit system;
            crossSystem = { config = "armv7l-unknown-linux-musleabihf"; };
          };
        in {
          aarch64Static = {
            pkgs = aarch64MuslPkgs.pkgsStatic;
            artifacts = mkArtifacts aarch64MuslPkgs.pkgsStatic "aarch64-linux" {};
            qemu = "qemu-aarch64";
          };
          armv7Static = {
            pkgs = armv7MuslPkgs.pkgsStatic;
            artifacts = mkArtifacts armv7MuslPkgs.pkgsStatic "armv7l-linux" {};
            qemu = "qemu-arm";
          };
          n900Static = {
            pkgs = armv7MuslPkgs.pkgsStatic;
            artifacts = mkArtifacts armv7MuslPkgs.pkgsStatic "armv7l-linux" {
              artifactSystemOverride = "linux-armv7-n900-musleabihf-static";
              extraCcFlags = [ "-mcpu=cortex-a8" "-mfpu=neon" "-mthumb" ];
            };
            qemu = "qemu-arm";
          };
        });

        crossArtifacts = lib.optionalAttrs (system == "x86_64-linux") {
          fen-linux-aarch64-musl-static = crossTargets.aarch64Static.artifacts.fenBinary;
          fen-linux-armv7-musleabihf-static = crossTargets.armv7Static.artifacts.fenBinary;
          fen-linux-armv7-n900-musleabihf-static = crossTargets.n900Static.artifacts.fenBinary;
        };

        crossChecks = lib.optionalAttrs (system == "x86_64-linux") {
          fenSmoke-linux-aarch64-musl-static = crossTargets.aarch64Static.artifacts.checks.fenQemuSmoke;
          fenNoStoreRefs-linux-aarch64-musl-static = crossTargets.aarch64Static.artifacts.checks.fenNoStoreRefs;
          fenNoDynamicDeps-linux-aarch64-musl-static = crossTargets.aarch64Static.artifacts.checks.fenNoDynamicDeps;
          fenSmoke-linux-armv7-musleabihf-static = crossTargets.armv7Static.artifacts.checks.fenQemuSmoke;
          fenNoStoreRefs-linux-armv7-musleabihf-static = crossTargets.armv7Static.artifacts.checks.fenNoStoreRefs;
          fenNoDynamicDeps-linux-armv7-musleabihf-static = crossTargets.armv7Static.artifacts.checks.fenNoDynamicDeps;
          fenSmoke-linux-armv7-n900-musleabihf-static = crossTargets.n900Static.artifacts.checks.fenQemuSmoke;
          fenNoStoreRefs-linux-armv7-n900-musleabihf-static = crossTargets.n900Static.artifacts.checks.fenNoStoreRefs;
          fenNoDynamicDeps-linux-armv7-n900-musleabihf-static = crossTargets.n900Static.artifacts.checks.fenNoDynamicDeps;
        };

        mkQemuApp = name: description: artifacts: qemu: {
          type = "app";
          program = toString (pkgs.writeShellScript name ''
            set -eu
            exec ${pkgs.pkgsStatic.qemu-user}/bin/${qemu} \
              ${artifacts.fenBinary}/bin/fen "$@"
          '');
          meta.description = description;
        };

        crossApps = lib.optionalAttrs (system == "x86_64-linux") {
          fen-aarch64-qemu = mkQemuApp "fen-aarch64-qemu"
            "Run the aarch64 fen binary under qemu"
            crossTargets.aarch64Static.artifacts crossTargets.aarch64Static.qemu;
          fen-armv7-qemu = mkQemuApp "fen-armv7-qemu"
            "Run the armv7 fen binary under qemu"
            crossTargets.armv7Static.artifacts crossTargets.armv7Static.qemu;
        };
      in {
        packages = {
          default = native.fenBinary;
          fen = native.fenBinary;
          fenSingleStatic = native.fenBinary;
          scratchImage = native.scratchImage;
        } // crossArtifacts;

        checks = {
          inherit checkPins;
          fennelCheck = native.checks.fennelCheck;
          docs = native.checks.docs;
          tests = native.checks.tests;
          fenSmoke = native.checks.fenSmoke;
          fenMockProviderSmoke = native.checks.fenMockProviderSmoke;
          fenOverlaySmoke = native.checks.fenOverlaySmoke;
          fenExtBuildSmoke = native.checks.fenExtBuildSmoke;
          fenNoStoreRefs = native.checks.fenNoStoreRefs;
          fenNoDynamicDeps = native.checks.fenNoDynamicDeps;
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

        devShells.default = devShell;
      });
}
