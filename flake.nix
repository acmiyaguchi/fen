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
        version = self.shortRev or self.dirtyShortRev or "unknown";

        artifactSystemFor = targetSystem:
          if targetSystem == "x86_64-linux" then "linux-x86_64"
          else if targetSystem == "aarch64-linux" then "linux-aarch64"
          else if targetSystem == "armv7l-linux" then "linux-armv7-gnueabihf"
          else targetSystem;

        dockerArchitectureFor = targetSystem:
          if targetSystem == "x86_64-linux" then "amd64"
          else if targetSystem == "aarch64-linux" then "arm64"
          else if targetSystem == "armv7l-linux" then "arm"
          else null;

        qemuFor = targetSystem:
          if targetSystem == "aarch64-linux" then "qemu-aarch64"
          else if targetSystem == "armv7l-linux" then "qemu-arm"
          else null;

        mkArtifacts = targetPkgs: targetSystem:
          let
            buildPkgs = targetPkgs.buildPackages;
            lua = targetPkgs.lua5_4;
            kubazipStatic = targetPkgs.kubazip.overrideAttrs (old: {
              cmakeFlags = (old.cmakeFlags or []) ++ [ "-DBUILD_SHARED_LIBS=OFF" ];
            });
            luaPkgs = targetPkgs.lua54Packages;
            buildLuaPkgs = buildPkgs.lua54Packages;
            luarocks54 = luaPkgs.luarocks or (targetPkgs.luarocks.override { lua = lua; });
            # Runtime rocks available directly from nixpkgs. Fennel is copied
            # separately as pure Lua from buildPackages so cross bundles can
            # support .fnl extensions without pulling in target fennel's
            # build-host Lua wrapper reference.
            nixpkgsRocks = with luaPkgs; [ lua-cjson luaposix luasocket ];
            testRocks = with luaPkgs; [ busted ];
            luaEnv = lua.withPackages (_: nixpkgsRocks);
            artifactSystem = artifactSystemFor targetSystem;
            dockerArchitecture = dockerArchitectureFor targetSystem;
            qemu = qemuFor targetSystem;
            isCross = targetPkgs.stdenv.buildPlatform.system != targetPkgs.stdenv.hostPlatform.system;
            fenPackage = artifacts.package;
            runtimeFennel = buildPkgs.lua54Packages.fennel;
            runtimeClosure = targetPkgs.closureInfo {
              rootPaths = [ lua luaEnv targetPkgs.curl targetPkgs.libxcrypt ];
            };
            artifacts = rec {
              package = targetPkgs.stdenv.mkDerivation {
                pname = "fen";
                inherit version;
                src = ./.;

                nativeBuildInputs = [
                  buildPkgs.makeWrapper
                  buildPkgs.pkg-config
                  buildPkgs.lua54Packages.fennel
                ];

                buildInputs = [
                  lua
                  targetPkgs.curl
                  targetPkgs.libxcrypt
                ];

                buildPhase = ''
                  runHook preBuild
                  FENNEL=${buildPkgs.lua54Packages.fennel}/bin/fennel \
                    LUA_INCDIR=${lua}/include \
                    CURL_INCDIR=${targetPkgs.curl.dev}/include \
                    CURL_LIBDIR=${targetPkgs.curl.out}/lib \
                    VERSION=${version} \
                    sh scripts/build-dist-tree.sh
                  runHook postBuild
                '';

                installPhase = ''
                  runHook preInstall

                  mkdir -p "$out/share/lua/5.4" "$out/lib/lua/5.4" "$out/share/fen/bin" "$out/bin"

                  # Merge every package's compiled Lua modules into one Lua search root.
                  for d in packages/*/dist packages/*/*/dist; do
                    if [ -d "$d" ]; then
                      cp -R "$d"/. "$out/share/lua/5.4/"
                    fi
                  done

                  # The termbox2 binding is a C module required as `termbox2`.
                  if [ -f packages/extensions/tui/dist/termbox2.so ]; then
                    install -Dm755 packages/extensions/tui/dist/termbox2.so \
                      "$out/lib/lua/5.4/termbox2.so"
                    rm -f "$out/share/lua/5.4/termbox2.so"
                  fi

                  # Project-owned libcurl binding required as `fen_http`.
                  if [ -f packages/util/dist/fen_http.so ]; then
                    install -Dm755 packages/util/dist/fen_http.so \
                      "$out/lib/lua/5.4/fen_http.so"
                    rm -f "$out/share/lua/5.4/fen_http.so"
                  fi

                  install -Dm644 bin/fen.lua "$out/share/fen/bin/fen.lua"
                  install -Dm644 ${runtimeFennel}/share/lua/5.4/fennel.lua \
                    "$out/share/lua/5.4/fennel.lua"

                  makeWrapper ${luaEnv}/bin/lua "$out/bin/fen" \
                    --prefix LUA_PATH ';' "$out/share/lua/5.4/?.lua;$out/share/lua/5.4/?/init.lua" \
                    --prefix LUA_CPATH ';' "$out/lib/lua/5.4/?.so" \
                    --add-flags "$out/share/fen/bin/fen.lua"

                  runHook postInstall
                '';

                meta = {
                  description = "Minimal Lua/Fennel coding-agent CLI";
                  mainProgram = "fen";
                };
              };

              fenSingle = targetPkgs.stdenv.mkDerivation {
                pname = "fen-single";
                inherit version;
                src = ./.;

                nativeBuildInputs = [
                  buildPkgs.coreutils
                  buildPkgs.findutils
                  buildPkgs.removeReferencesTo
                  buildPkgs.zip
                ];

                buildInputs = [
                  lua
                  kubazipStatic
                ];

                dontUnpack = true;
                dontStrip = true;

                buildPhase = ''
                  runHook preBuild

                  mkdir -p archive-root build
                  cp -R ${fenPackage}/share/lua/5.4/. archive-root/

                  # Deterministic zip input: stable mode/mtime/order and no
                  # host-specific extra fields. The embedded searcher expects
                  # module-relative paths such as fen/core/agent.lua.
                  chmod -R u+rwX,go+rX archive-root
                  find archive-root -exec touch -h -d @1 {} +
                  (cd archive-root && find . -type f -print | sort | sed 's#^./##' \
                    | zip -q -X -9 ../build/fen-lua.zip -@)

                  cp ${./launcher/fen-single.c} build/fen-single.c
                  $CC -O2 -Wall \
                    -I${lua}/include \
                    -I${kubazipStatic.dev}/include \
                    build/fen-single.c \
                    -L${lua}/lib -L${kubazipStatic}/lib \
                    -Wl,-Bstatic -lzip -llua -Wl,-Bdynamic -lm -ldl \
                    -o build/fen
                  cat build/fen-lua.zip >> build/fen
                  chmod +x build/fen

                  runHook postBuild
                '';

                installPhase = ''
                  runHook preInstall
                  install -Dm755 build/fen "$out/bin/fen"
                  remove-references-to -t ${lua} "$out/bin/fen"
                  runHook postInstall
                '';

                meta = {
                  description = "Single-file prototype of the fen CLI with embedded Lua ZIP archive";
                  mainProgram = "fen";
                };
              };

              singleSmoke = targetPkgs.runCommand "fen-${version}-${artifactSystem}-single-smoke"
                {
                  nativeBuildInputs = [ buildPkgs.coreutils ];
                }
                ''
                  ${fenSingle}/bin/fen --help > "$out"
                '';

              singleDevSmoke = targetPkgs.runCommand "fen-${version}-${artifactSystem}-single-dev-smoke"
                {
                  nativeBuildInputs = [ buildPkgs.coreutils ];
                }
                ''
                  ${fenSingle}/bin/fen \
                    --dev-path ${./tests/fixtures/dev-path-sentinel} \
                    --help > "$out"
                  grep -q DEV-PATH-OK "$out"
                '';

              singleExtRootSmoke = targetPkgs.runCommand "fen-${version}-${artifactSystem}-single-ext-root-smoke"
                {
                  nativeBuildInputs = [ buildPkgs.coreutils ];
                }
                ''
                  ${fenSingle}/bin/fen \
                    --dev-path ${./tests/fixtures/extension-root-sentinel/fen-main-stub} \
                    --extension-root ${./tests/fixtures/extension-root-sentinel} \
                    > "$out"
                  grep -q EXT-ROOT-OK "$out"
                '';

              fennelCheck = targetPkgs.runCommand "fen-${version}-${artifactSystem}-fennel-check"
                {
                  nativeBuildInputs = [ buildLuaPkgs.fennel buildPkgs.findutils ];
                }
                ''
                  cd ${./.}
                  FENNEL=${buildLuaPkgs.fennel}/bin/fennel sh scripts/check-fennel.sh
                  touch "$out"
                '';

              tests = targetPkgs.runCommand "fen-${version}-${artifactSystem}-tests"
                {
                  nativeBuildInputs = [
                    buildPkgs.coreutils
                    buildPkgs.stdenv.cc
                    buildPkgs.curl
                    buildLuaPkgs.fennel
                    buildLuaPkgs.busted
                    buildLuaPkgs.lua-cjson
                    buildLuaPkgs.luaposix
                    buildLuaPkgs.luasocket
                  ];
                }
                ''
                  cp -R ${./.} source
                  chmod -R u+w source
                  cd source
                  export HOME=$TMPDIR/home
                  export XDG_STATE_HOME=$TMPDIR/state
                  export XDG_CONFIG_HOME=$TMPDIR/config
                  mkdir -p "$HOME" "$XDG_STATE_HOME" "$XDG_CONFIG_HOME"
                  LUA_INCDIR=${buildPkgs.lua5_4}/include \
                    CURL_INCDIR=${buildPkgs.curl.dev}/include \
                    CURL_LIBDIR=${buildPkgs.curl.out}/lib \
                    sh scripts/build-native-modules.sh
                  sh scripts/run-tests.sh
                  touch "$out"
                '';

              binFenDevSmoke = targetPkgs.runCommand "fen-${version}-${artifactSystem}-bin-fen-dev-smoke"
                {
                  nativeBuildInputs = [ buildPkgs.coreutils ];
                }
                ''
                  cp -R ${./.} checkout
                  chmod -R u+w checkout
                  sed -i 's/fen — minimal/BIN-FEN-DEV-OK fen — minimal/' \
                    checkout/packages/fen/src/fen/main.fnl
                  FEN_BIN=${fenSingle}/bin/fen checkout/bin/fen-dev --help > "$out"
                  grep -q BIN-FEN-DEV-OK "$out"
                '';

              singleQemuSmoke = pkgs.runCommand "fen-${version}-${artifactSystem}-single-qemu-smoke"
                {
                  nativeBuildInputs = [ pkgs.coreutils pkgs.pkgsStatic.qemu-user ];
                }
                ''
                  ${pkgs.pkgsStatic.qemu-user}/bin/${qemu} ${fenSingle}/bin/fen --help > "$out"
                '';

              distTree = targetPkgs.runCommand "fen-${version}-${artifactSystem}-dist-tree"
                {
                  nativeBuildInputs = [ buildPkgs.coreutils buildPkgs.findutils buildPkgs.gawk buildPkgs.patchelf ];
                  FEN_PKG = fenPackage;
                  FEN_LUA = lua;
                  FEN_LUA_ENV = luaEnv;
                  FEN_FENNEL_LUA = "${runtimeFennel}/share/lua/5.4/fennel.lua";
                  FEN_RUNTIME_CLOSURE = runtimeClosure;
                  FEN_LD_INTERP = targetPkgs.stdenv.cc.bintools.dynamicLinker;
                  FEN_CROSS_BUNDLE = if isCross then "1" else "";
                  FEN_TARGET_CONFIG = targetPkgs.stdenv.hostPlatform.config;
                  FEN_VERSION = version;
                  FEN_ARTIFACT_SYSTEM = artifactSystem;
                  FEN_BUNDLE_FORMAT = "tree";
                }
                ''
                  sh ${./scripts/nix-bundle-linux.sh} "$out"
                '';

              dist = targetPkgs.runCommand "fen-${version}-${artifactSystem}-dist"
                {
                  nativeBuildInputs = [ buildPkgs.coreutils buildPkgs.findutils buildPkgs.gawk buildPkgs.gnutar buildPkgs.gzip buildPkgs.patchelf ];
                  FEN_PKG = fenPackage;
                  FEN_LUA = lua;
                  FEN_LUA_ENV = luaEnv;
                  FEN_FENNEL_LUA = "${runtimeFennel}/share/lua/5.4/fennel.lua";
                  FEN_RUNTIME_CLOSURE = runtimeClosure;
                  FEN_LD_INTERP = targetPkgs.stdenv.cc.bintools.dynamicLinker;
                  FEN_CROSS_BUNDLE = if isCross then "1" else "";
                  FEN_TARGET_CONFIG = targetPkgs.stdenv.hostPlatform.config;
                  FEN_VERSION = version;
                  FEN_ARTIFACT_SYSTEM = artifactSystem;
                  FEN_BUNDLE_FORMAT = "tar";
                }
                ''
                  sh ${./scripts/nix-bundle-linux.sh} "$out"
                '';

              distSmoke = targetPkgs.runCommand "fen-${version}-${artifactSystem}-dist-smoke"
                {
                  nativeBuildInputs = [ buildPkgs.coreutils ];
                }
                ''
                  ${distTree}/opt/fen/bin/fen --help > "$out"
                  ld_interp=$(echo ${targetPkgs.stdenv.cc.bintools.dynamicLinker})
                  LUA_PATH="${distTree}/opt/fen/share/lua/5.4/?.lua;${distTree}/opt/fen/share/lua/5.4/?/init.lua;;" \
                    ${distTree}/opt/fen/lib/$(basename "$ld_interp") \
                    --library-path ${distTree}/opt/fen/lib \
                    ${distTree}/opt/fen/libexec/lua \
                    -e 'assert(require("fennel").dofile("${./tests/fixtures/fnl-extension}/init.fnl"))' \
                    >> "$out"
                '';

              qemuSmoke = pkgs.runCommand "fen-${version}-${artifactSystem}-qemu-smoke"
                {
                  nativeBuildInputs = [ pkgs.coreutils pkgs.pkgsStatic.qemu-user ];
                }
                ''
                  tree=${distTree}/opt/fen
                  ld_interp=$(echo ${targetPkgs.stdenv.cc.bintools.dynamicLinker})
                  export LUA_PATH="$tree/share/lua/5.4/?.lua;$tree/share/lua/5.4/?/init.lua;;"
                  export LUA_CPATH="$tree/lib/lua/5.4/?.so;;"
                  ${pkgs.pkgsStatic.qemu-user}/bin/${qemu} \
                    "$tree/lib/$(basename "$ld_interp")" \
                    --library-path "$tree/lib" \
                    "$tree/libexec/lua" \
                    "$tree/share/fen/bin/fen.lua" --help > "$out"
                  LUA_PATH="$tree/share/lua/5.4/?.lua;$tree/share/lua/5.4/?/init.lua;;" \
                    ${pkgs.pkgsStatic.qemu-user}/bin/${qemu} \
                    "$tree/lib/$(basename "$ld_interp")" \
                    --library-path "$tree/lib" \
                    "$tree/libexec/lua" \
                    -e 'assert(require("fennel").dofile("${./tests/fixtures/fnl-extension}/init.fnl"))' \
                    >> "$out"
                '';

              distScratchImage = targetPkgs.dockerTools.buildImage {
                name = "fen-dist-scratch-test";
                tag = version;
                architecture = dockerArchitecture;
                copyToRoot = targetPkgs.runCommand "fen-${version}-${artifactSystem}-scratch-root" {} ''
                  mkdir -p "$out/bin" "$out/etc/ssl/certs" "$out/tmp"
                  chmod 1777 "$out/tmp"
                  cp -a ${distTree}/opt "$out/opt"
                  cp -L ${targetPkgs.pkgsStatic.busybox}/bin/busybox "$out/bin/busybox"
                  ${targetPkgs.pkgsStatic.busybox}/bin/busybox --list | while IFS= read -r applet; do
                    ln -sf busybox "$out/bin/$applet"
                  done
                  cp ${targetPkgs.cacert}/etc/ssl/certs/ca-bundle.crt \
                    "$out/etc/ssl/certs/ca-bundle.crt"
                '';
                config = {
                  Env = [
                    "PATH=/bin"
                    "TMPDIR=/tmp"
                    "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
                    "CURL_CA_BUNDLE=/etc/ssl/certs/ca-bundle.crt"
                  ];
                  Entrypoint = [ "/opt/fen/bin/fen" ];
                };
              };

              devShell = targetPkgs.mkShell {
                packages = [
                  lua
                  luarocks54
                  targetPkgs.curl
                  targetPkgs.curl.dev
                  targetPkgs.libxcrypt
                  targetPkgs.lua54Packages.fennel
                  targetPkgs.stylua
                  targetPkgs.gnumake
                  targetPkgs.gcc
                ] ++ nixpkgsRocks ++ testRocks;
                shellHook = ''
                  export FEN_LUA=${lua}/bin/lua
                  export LUAROCKS=${luarocks54}/bin/luarocks
                  # Lua headers for compiling vendor/lua_termbox2.c via the Makefile.
                  export LUA_INCDIR=${lua}/include
                  export CURL_INCDIR=${targetPkgs.curl.dev}/include
                  export CURL_LIBDIR=${targetPkgs.curl.out}/lib
                  export CPATH=${targetPkgs.libxcrypt}/include:$CPATH
                  export LIBRARY_PATH=${targetPkgs.libxcrypt}/lib:$LIBRARY_PATH
                  export LD_LIBRARY_PATH=${targetPkgs.libxcrypt}/lib:$LD_LIBRARY_PATH
                  # Make rocks installed into lua_modules/ visible, plus dist/ for
                  # the vendored termbox2.so produced by `make build`.
                  export LUA_PATH="$PWD/lua_modules/share/lua/5.4/?.lua;$PWD/lua_modules/share/lua/5.4/?/init.lua;$LUA_PATH"
                  export LUA_CPATH="$PWD/packages/extensions/tui/dist/?.so;$PWD/lua_modules/lib/lua/5.4/?.so;$LUA_CPATH"
                  # Project bin/ + locally installed rocks both on PATH.
                  export PATH="$PWD/bin:$PWD/lua_modules/bin:$PATH"
                '';
              };
            };
          in artifacts;

        native = mkArtifacts pkgs system;

        crossArtifacts = lib.optionalAttrs (system == "x86_64-linux")
          (let
            aarch64Pkgs = import nixpkgs {
              inherit system;
              crossSystem = lib.systems.examples.aarch64-multiplatform;
            };
            armv7Pkgs = import nixpkgs {
              inherit system;
              crossSystem = lib.systems.examples.armv7l-hf-multiplatform;
            };
            aarch64 = mkArtifacts aarch64Pkgs "aarch64-linux";
            armv7 = mkArtifacts armv7Pkgs "armv7l-linux";
          in {
            dist-linux-aarch64 = aarch64.dist;
            distTree-linux-aarch64 = aarch64.distTree;
            fenSingle-linux-aarch64 = aarch64.fenSingle;
            distScratchImage-linux-aarch64 = aarch64.distScratchImage;
            dist-linux-armv7-gnueabihf = armv7.dist;
            distTree-linux-armv7-gnueabihf = armv7.distTree;
            fenSingle-linux-armv7-gnueabihf = armv7.fenSingle;
            distScratchImage-linux-armv7-gnueabihf = armv7.distScratchImage;
          });

        crossChecks = lib.optionalAttrs (system == "x86_64-linux")
          (let
            aarch64Pkgs = import nixpkgs {
              inherit system;
              crossSystem = lib.systems.examples.aarch64-multiplatform;
            };
            armv7Pkgs = import nixpkgs {
              inherit system;
              crossSystem = lib.systems.examples.armv7l-hf-multiplatform;
            };
            aarch64 = mkArtifacts aarch64Pkgs "aarch64-linux";
            armv7 = mkArtifacts armv7Pkgs "armv7l-linux";
          in {
            qemuSmoke-linux-aarch64 = aarch64.qemuSmoke;
            singleSmoke-linux-aarch64 = aarch64.singleQemuSmoke;
            qemuSmoke-linux-armv7-gnueabihf = armv7.qemuSmoke;
            singleSmoke-linux-armv7-gnueabihf = armv7.singleQemuSmoke;
          });

        crossApps = lib.optionalAttrs (system == "x86_64-linux")
          (let
            aarch64Pkgs = import nixpkgs {
              inherit system;
              crossSystem = lib.systems.examples.aarch64-multiplatform;
            };
            armv7Pkgs = import nixpkgs {
              inherit system;
              crossSystem = lib.systems.examples.armv7l-hf-multiplatform;
            };
            aarch64 = mkArtifacts aarch64Pkgs "aarch64-linux";
            armv7 = mkArtifacts armv7Pkgs "armv7l-linux";
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
          in {
            fen-aarch64-qemu = mkQemuApp "fen-aarch64-qemu" aarch64Pkgs aarch64 "qemu-aarch64";
            fen-armv7-qemu = mkQemuApp "fen-armv7-qemu" armv7Pkgs armv7 "qemu-arm";
          });
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
          distSmoke = native.distSmoke;
          fennelCheck = native.fennelCheck;
          tests = native.tests;
          singleSmoke = native.singleSmoke;
          singleDevSmoke = native.singleDevSmoke;
          singleExtRootSmoke = native.singleExtRootSmoke;
          binFenDevSmoke = native.binFenDevSmoke;
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
