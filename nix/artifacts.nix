{
  pkgs,
  targetPkgs,
  version,
  targetSystem,
  artifactSystemFor,
  dockerArchitectureFor,
  qemuFor,
}:

let
  buildPkgs = targetPkgs.buildPackages;
  lua = targetPkgs.lua5_4;
  kubazipStatic = targetPkgs.kubazip.overrideAttrs (old: {
    cmakeFlags = (old.cmakeFlags or []) ++ [ "-DBUILD_SHARED_LIBS=OFF" ];
  });
  luaPkgs = targetPkgs.lua54Packages;
  buildLuaPkgs = buildPkgs.lua54Packages;
  luarocks54 = luaPkgs.luarocks or (targetPkgs.luarocks.override { lua = lua; });
  nixpkgsRocks = with luaPkgs; [ lua-cjson luaposix luasocket ];
  testRocks = with luaPkgs; [ busted ];
  luaEnv = lua.withPackages (_: nixpkgsRocks);
  artifactSystem = artifactSystemFor targetSystem;
  dockerArchitecture = dockerArchitectureFor targetSystem;
  qemu = qemuFor targetSystem;
  isCross = targetPkgs.stdenv.buildPlatform.system != targetPkgs.stdenv.hostPlatform.system;
  runtimeFennel = buildPkgs.lua54Packages.fennel;
  runtimeClosure = targetPkgs.closureInfo {
    rootPaths = [ lua luaEnv targetPkgs.curl targetPkgs.libxcrypt ];
  };

  bundleEnv = {
    FEN_PKG = artifacts.package;
    FEN_LUA = lua;
    FEN_LUA_ENV = luaEnv;
    FEN_FENNEL_LUA = "${runtimeFennel}/share/lua/5.4/fennel.lua";
    FEN_RUNTIME_CLOSURE = runtimeClosure;
    FEN_LD_INTERP = targetPkgs.stdenv.cc.bintools.dynamicLinker;
    FEN_CROSS_BUNDLE = if isCross then "1" else "";
    FEN_TARGET_CONFIG = targetPkgs.stdenv.hostPlatform.config;
    FEN_VERSION = version;
    FEN_ARTIFACT_SYSTEM = artifactSystem;
  };

  artifacts = rec {
    package = targetPkgs.stdenv.mkDerivation {
      pname = "fen";
      inherit version;
      src = ../.;

      nativeBuildInputs = [
        buildPkgs.makeWrapper
        buildPkgs.pkg-config
        buildPkgs.lua54Packages.fennel
      ];

      buildInputs = [ lua targetPkgs.curl targetPkgs.libxcrypt ];

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

        for d in packages/*/dist packages/*/*/dist; do
          if [ -d "$d" ]; then
            cp -R "$d"/. "$out/share/lua/5.4/"
          fi
        done

        if [ -f packages/extensions/tui/dist/termbox2.so ]; then
          install -Dm755 packages/extensions/tui/dist/termbox2.so \
            "$out/lib/lua/5.4/termbox2.so"
          rm -f "$out/share/lua/5.4/termbox2.so"
        fi

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
      src = ../.;

      nativeBuildInputs = [
        buildPkgs.coreutils
        buildPkgs.findutils
        buildPkgs.removeReferencesTo
        buildPkgs.zip
      ];

      buildInputs = [ lua kubazipStatic ];
      dontUnpack = true;
      dontStrip = true;

      buildPhase = ''
        runHook preBuild

        mkdir -p archive-root build
        cp -R ${package}/share/lua/5.4/. archive-root/

        chmod -R u+rwX,go+rX archive-root
        find archive-root -exec touch -h -d @1 {} +
        (cd archive-root && find . -type f -print | sort | sed 's#^./##' \
          | zip -q -X -9 ../build/fen-lua.zip -@)

        cp ${../launcher/fen-single.c} build/fen-single.c
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

    distTree = targetPkgs.runCommand "fen-${version}-${artifactSystem}-dist-tree"
      (bundleEnv // {
        nativeBuildInputs = [ buildPkgs.coreutils buildPkgs.findutils buildPkgs.gawk buildPkgs.patchelf ];
        FEN_BUNDLE_FORMAT = "tree";
      })
      ''
        sh ${../scripts/nix-bundle-linux.sh} "$out"
      '';

    dist = targetPkgs.runCommand "fen-${version}-${artifactSystem}-dist"
      (bundleEnv // {
        nativeBuildInputs = [ buildPkgs.coreutils buildPkgs.findutils buildPkgs.gawk buildPkgs.gnutar buildPkgs.gzip buildPkgs.patchelf ];
        FEN_BUNDLE_FORMAT = "tar";
      })
      ''
        sh ${../scripts/nix-bundle-linux.sh} "$out"
      '';

    distScratchImage = import ./docker.nix {
      inherit targetPkgs version artifactSystem dockerArchitecture distTree;
    };

    checks = import ./checks.nix {
      inherit pkgs targetPkgs buildPkgs buildLuaPkgs version artifactSystem qemu fenSingle distTree;
    };

    devShell = import ./dev-shell.nix {
      inherit targetPkgs lua luarocks54 nixpkgsRocks testRocks;
    };
  };
in
artifacts
