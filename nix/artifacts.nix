{
  pkgs,
  targetPkgs,
  version,
  targetSystem,
  artifactSystemFor,
  dockerArchitectureFor,
  qemuFor,
  dynamicLinkerFor,
}:

let
  buildPkgs = targetPkgs.buildPackages;
  lua = targetPkgs.lua5_4;
  kubazipStatic = targetPkgs.kubazip.overrideAttrs (old: {
    cmakeFlags = (old.cmakeFlags or []) ++ [ "-DBUILD_SHARED_LIBS=OFF" ];
  });
  fenOpenSSLStatic = targetPkgs.openssl.overrideAttrs (old: {
    configureFlags = (old.configureFlags or []) ++ [ "no-shared" ];
  });
  fenCurlStatic = targetPkgs.curl.overrideAttrs (old: {
    buildInputs = (old.buildInputs or []) ++ [ fenOpenSSLStatic ];
    configureFlags = (old.configureFlags or []) ++ [
      "--disable-shared"
      "--enable-static"
      "--with-openssl=${fenOpenSSLStatic.dev}"
      "--disable-manual"
      "--disable-ftp"
      "--disable-file"
      "--disable-ldap"
      "--disable-ldaps"
      "--disable-rtsp"
      "--disable-dict"
      "--disable-telnet"
      "--disable-tftp"
      "--disable-pop3"
      "--disable-imap"
      "--disable-smb"
      "--disable-smtp"
      "--disable-gopher"
      "--disable-mqtt"
      "--without-libidn2"
      "--without-libpsl"
      "--without-nghttp2"
      "--without-nghttp3"
      "--without-ngtcp2"
      "--without-brotli"
      "--without-zstd"
      "--without-zlib"
      "--without-libssh2"
      "--without-gssapi"
    ];
  });
  luaPkgs = targetPkgs.lua54Packages;
  buildLuaPkgs = buildPkgs.lua54Packages;
  luarocks54 = luaPkgs.luarocks or (targetPkgs.luarocks.override { lua = lua; });
  nixpkgsRocks = with luaPkgs; [ lua-cjson luasocket ];
  testRocks = with luaPkgs; [ busted ];
  luaEnv = lua.withPackages (_: nixpkgsRocks);
  artifactSystem = artifactSystemFor targetSystem;
  dockerArchitecture = dockerArchitectureFor targetSystem;
  qemu = qemuFor targetSystem;
  dynamicLinker = dynamicLinkerFor targetSystem;
  isCross = targetPkgs.stdenv.buildPlatform.system != targetPkgs.stdenv.hostPlatform.system;
  runtimeFennel = buildPkgs.lua54Packages.fennel;
  runtimeClosure = targetPkgs.closureInfo {
    rootPaths = [ lua luaEnv targetPkgs.curl targetPkgs.libxcrypt ];
  };
  luaCjsonSrc = targetPkgs.lua54Packages.lua-cjson.src;
  luaLfsSrc = targetPkgs.lua54Packages.luafilesystem.src;
  dkjson = targetPkgs.lua54Packages.dkjson;

  fenBinaryLua = targetPkgs.stdenv.mkDerivation {
    pname = "fen-binary-lua";
    version = lua.version or "5.4";
    src = targetPkgs.lua5_4.src;

    nativeBuildInputs = [ buildPkgs.gnumake ];

    postPatch = ''
      sed -i 's|#define LUA_ROOT.*|#define LUA_ROOT "/usr/"|' src/luaconf.h
    '';

    buildPhase = ''
      runHook preBuild
      make linux CC="$CC" AR="$AR rcu" RANLIB="$RANLIB" \
        MYCFLAGS='-DLUA_USE_LINUX' \
        MYLIBS='-lm -ldl'
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/include" "$out/lib"
      cp src/lua.h src/luaconf.h src/lualib.h src/lauxlib.h src/lua.hpp "$out/include"/
      cp src/liblua.a "$out/lib"/
      runHook postInstall
    '';
  };

  fenBinaryObjects = targetPkgs.stdenv.mkDerivation {
    pname = "fen-binary-objects";
    inherit version;
    src = ../.;

    nativeBuildInputs = [ buildPkgs.coreutils ];
    buildInputs = [ fenBinaryLua fenCurlStatic ];

    dontConfigure = true;

    buildPhase = ''
      runHook preBuild
      mkdir -p obj cjson-src lfs-src
      cp -R ${luaCjsonSrc}/. cjson-src/
      cp -R ${luaLfsSrc}/. lfs-src/
      chmod -R u+w cjson-src lfs-src

      $CC -O2 -Wall -I${fenBinaryLua}/include \
        -c packages/extensions/tui/vendor/lua_termbox2.c \
        -o obj/lua_termbox2.o

      $CC -O2 -Wall -I${fenBinaryLua}/include \
        -I${fenCurlStatic.dev}/include \
        -c packages/util/vendor/fen_http.c \
        -o obj/fen_http.o

      $CC -O2 -Wall -I${fenBinaryLua}/include \
        -c packages/util/vendor/fen_process.c \
        -o obj/fen_process.o

      $CC -O2 -Wall -I${fenBinaryLua}/include \
        -c lfs-src/src/lfs.c \
        -o obj/lfs.o

      $CC -O2 -Wall -DNDEBUG -fPIC -I${fenBinaryLua}/include \
        -c cjson-src/lua_cjson.c \
        -o obj/lua_cjson.o
      $CC -O2 -Wall -DNDEBUG -fPIC -I${fenBinaryLua}/include \
        -c cjson-src/strbuf.c \
        -o obj/strbuf.o
      $CC -O2 -Wall -DNDEBUG -fPIC -I${fenBinaryLua}/include \
        -c cjson-src/fpconv.c \
        -o obj/fpconv.o
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp obj/*.o "$out"/
      runHook postInstall
    '';
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
      pname = "fen-lua";
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

        if [ -f packages/util/dist/fen_process.so ]; then
          install -Dm755 packages/util/dist/fen_process.so \
            "$out/lib/lua/5.4/fen_process.so"
          rm -f "$out/share/lua/5.4/fen_process.so"
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

    fenBinary = targetPkgs.stdenv.mkDerivation {
      pname = "fen";
      inherit version;
      src = ../.;

      nativeBuildInputs = [
        buildPkgs.coreutils
        buildPkgs.findutils
        buildPkgs.patchelf
        buildPkgs.perl
        buildPkgs.removeReferencesTo
        buildPkgs.zip
      ];

      buildInputs = [ fenBinaryLua kubazipStatic fenCurlStatic fenOpenSSLStatic.dev fenOpenSSLStatic.out ];
      dontUnpack = true;
      dontStrip = true;

      buildPhase = ''
        runHook preBuild

        mkdir -p archive-root build
        cp -R ${package}/share/lua/5.4/. archive-root/
        cp -R ${luarocks54}/share/lua/5.4/luarocks archive-root/luarocks
        cp -R ${dkjson}/share/lua/5.4/. archive-root/

        chmod -R u+rwX,go+rX archive-root
        find archive-root -exec touch -h -d @1 {} +
        (cd archive-root && find . -type f -print | sort | sed 's#^./##' \
          | zip -q -X -9 ../build/fen-lua.zip -@)

        cp ${../launcher/fen-binary.c} build/fen-binary.c
        export PKG_CONFIG_PATH=${fenCurlStatic.dev}/lib/pkgconfig:${fenCurlStatic.out}/lib/pkgconfig:${fenOpenSSLStatic.dev}/lib/pkgconfig:''${PKG_CONFIG_PATH:-}
        curl_static_libs="$(${pkgs.pkg-config}/bin/pkg-config --static --libs libcurl | sed 's/ -ldl//g')"
        $CC -O2 -Wall \
          -I${fenBinaryLua}/include \
          -I${kubazipStatic.dev}/include \
          build/fen-binary.c \
          ${fenBinaryObjects}/*.o \
          -L${fenBinaryLua}/lib -L${kubazipStatic}/lib \
          -Wl,-Bstatic -lzip -llua $curl_static_libs -Wl,-Bdynamic \
          -lm -ldl \
          -o build/fen
        if [ -n "${dynamicLinker}" ]; then
          patchelf --set-interpreter ${dynamicLinker} build/fen
        fi
        patchelf --remove-rpath build/fen || true
        cat build/fen-lua.zip >> build/fen
        chmod +x build/fen

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        install -Dm755 build/fen "$out/bin/fen"
        cp "$out/bin/fen" "$out/bin/fen-${version}-${artifactSystem}"
        remove-references-to -t ${fenBinaryLua} "$out/bin/fen" "$out/bin/fen-${version}-${artifactSystem}"
        # patchelf removes the dynamic tag, but Nix's link wrapper can leave
        # dead store-path strings in the ELF string table. Keep the byte length
        # stable so the appended ZIP offsets remain valid.
        perl -0pi -e 's#/nix/store#/no-/store#g' \
          "$out/bin/fen" "$out/bin/fen-${version}-${artifactSystem}"
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

    scratchImage = import ./docker.nix {
      inherit targetPkgs version artifactSystem dockerArchitecture fenBinary dynamicLinker;
    };

    checks = import ./checks.nix {
      inherit pkgs targetPkgs buildPkgs buildLuaPkgs version artifactSystem qemu fenBinary distTree;
    };

    devShell = import ./dev-shell.nix {
      inherit targetPkgs lua luarocks54 nixpkgsRocks testRocks;
    };
  };
in
artifacts
