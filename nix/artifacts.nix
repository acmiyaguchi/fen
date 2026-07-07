{
  pkgs,
  targetPkgs,
  version,
  versionInfo,
  targetSystem,
  artifactSystemFor,
  dockerArchitectureFor,
  qemuFor,
  artifactSystemOverride ? null,
  extraCcFlags ? [],
  dependencyExtraCcFlags ? extraCcFlags,
}:

let
  lib = pkgs.lib;
  buildPkgs = targetPkgs.buildPackages;
  lua = targetPkgs.lua5_4;
  buildLuaPkgs = buildPkgs.lua54Packages;
  # Target static rocks may not build as shared modules, so take the runtime
  # Lua sources (cjson, lfs, luasocket, dkjson, luarocks) from the build host.
  runtimeLuaPkgs = buildLuaPkgs;
  luarocks54 = runtimeLuaPkgs.luarocks or (targetPkgs.luarocks.override { lua = lua; });
  artifactSystem = if artifactSystemOverride != null then artifactSystemOverride else artifactSystemFor targetSystem;
  dockerArchitecture = dockerArchitectureFor targetSystem;
  qemu = qemuFor targetSystem;
  extraCcFlagsString = lib.concatStringsSep " " extraCcFlags;
  dependencyExtraCcFlagsString = lib.concatStringsSep " " dependencyExtraCcFlags;
  # Extra CPU/FPU flags always apply to fen-owned objects and the final launcher.
  # They can also be applied to third-party static dependencies, but cross builds
  # that only need a tuned fen wrapper can leave dependencyExtraCcFlags empty and
  # reuse the generic target's OpenSSL/curl/Lua/libzip outputs.
  ccSetup = lib.optionalString (extraCcFlags != []) ''
    export NIX_CFLAGS_COMPILE="''${NIX_CFLAGS_COMPILE:-} ${extraCcFlagsString}"
    export CFLAGS="''${CFLAGS:-} ${extraCcFlagsString}"
    export CXXFLAGS="''${CXXFLAGS:-} ${extraCcFlagsString}"
  '';
  dependencyCcSetup = lib.optionalString (dependencyExtraCcFlags != []) ''
    export NIX_CFLAGS_COMPILE="''${NIX_CFLAGS_COMPILE:-} ${dependencyExtraCcFlagsString}"
    export CFLAGS="''${CFLAGS:-} ${dependencyExtraCcFlagsString}"
    export CXXFLAGS="''${CXXFLAGS:-} ${dependencyExtraCcFlagsString}"
  '';
  tunedDependencyAttrs = old: lib.optionalAttrs (dependencyExtraCcFlags != []) {
    preConfigure = (old.preConfigure or "") + ''

      ${dependencyCcSetup}
    '';
  };
  kubazipStatic = targetPkgs.kubazip.overrideAttrs (old: {
    cmakeFlags = (old.cmakeFlags or []) ++ [ "-DBUILD_SHARED_LIBS=OFF" ];
    # kubazip 0.3.5 builds its vendored miniz with -Werror. miniz's 64-bit
    # overflow guards (e.g. `(mz_uint64)(a | b) > 0xFFFFFFFFU`) are tautologies
    # on 32-bit targets, where the OR is evaluated in 32-bit mz_ulong before the
    # cast, so -Wtype-limits fires and fails the armv7 cross build. Drop -Werror
    # (its own flag wins over wrapper -Wno-error) and keep the benign warnings.
    postPatch = (old.postPatch or "") + ''
      substituteInPlace CMakeLists.txt --replace-fail " -Werror" ""
    '';
  } // tunedDependencyAttrs old);
  fenOpenSSLStatic = targetPkgs.openssl.overrideAttrs (old: {
    configureFlags = (old.configureFlags or []) ++ [ "no-shared" ];
    # These overrides are only linked into the fen executable; upstream tests
    # are expensive for cross/static release builds and covered by fen smoke.
    doCheck = false;
  } // tunedDependencyAttrs old);
  fenCurlStatic = (targetPkgs.curl.override {
    openssl = fenOpenSSLStatic;
    opensslSupport = true;
    gnutlsSupport = false;
    rustlsSupport = false;
    wolfsslSupport = false;
    zlibSupport = false;
    brotliSupport = false;
    zstdSupport = false;
    idnSupport = false;
    pslSupport = false;
    http2Support = false;
    http3Support = false;
    scpSupport = false;
    ldapSupport = false;
    rtmpSupport = false;
    gssSupport = false;
    gsaslSupport = false;
    c-aresSupport = false;
    websocketSupport = false;
  }).overrideAttrs (old: {
    doCheck = false;
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
  } // tunedDependencyAttrs old);
  luaMyCFlags = "-DLUA_USE_POSIX";
  luaMyLibs = "-lm";
  runtimeFennel = runtimeLuaPkgs.fennel;
  pkgConfig = "${buildPkgs.pkg-config}/bin/${targetPkgs.stdenv.cc.targetPrefix}pkg-config";
  luaCjsonSrc = runtimeLuaPkgs.lua-cjson.src;
  luaLfsSrc = runtimeLuaPkgs.luafilesystem.src;
  luaSocketSrc = runtimeLuaPkgs.luasocket.src;
  dkjson = runtimeLuaPkgs.dkjson;

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
      ${dependencyCcSetup}
      make linux CC="$CC" AR="$AR rcu" RANLIB="$RANLIB" \
        MYCFLAGS='${luaMyCFlags}' \
        MYLIBS='${luaMyLibs}'
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
    dontFixup = true;

    buildPhase = ''
      runHook preBuild
      ${ccSetup}
      mkdir -p obj cjson-src lfs-src luasocket-src
      cp -R ${luaCjsonSrc}/. cjson-src/
      cp -R ${luaLfsSrc}/. lfs-src/
      cp -R ${luaSocketSrc}/. luasocket-src/
      chmod -R u+w cjson-src lfs-src luasocket-src

      $CC -O2 -Wall -I${fenBinaryLua}/include \
        -c extensions/adapters/presenters/tui/vendor/lua_termbox2.c \
        -o obj/lua_termbox2.o

      $CC -O2 -Wall -I${fenBinaryLua}/include \
        -I${fenCurlStatic.dev}/include \
        -c packages/util/vendor/fen_http.c \
        -o obj/fen_http.o

      $CC -O2 -Wall -I${fenBinaryLua}/include \
        -c packages/util/vendor/fen_process.c \
        -o obj/fen_process.o

      $CC -O2 -Wall -I${fenBinaryLua}/include \
        -c packages/util/vendor/fen_random.c \
        -o obj/fen_random.o


      $CC -O2 -Wall -I${fenBinaryLua}/include \
        -c lfs-src/src/lfs.c \
        -o obj/lfs.o

      # LuaSocket C module list is shared with the Makefile's non-Nix build via
      # scripts/build/luasocket-c-modules.txt (single source of truth).
      for base in $(cat scripts/build/luasocket-c-modules.txt); do
        $CC -O2 -Wall -DLUASOCKET_NODEBUG \
          -I${fenBinaryLua}/include -Iluasocket-src/src \
          -c "luasocket-src/src/$base.c" \
          -o "obj/luasocket-$base.o"
      done

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

  luaTree = targetPkgs.stdenv.mkDerivation {
    pname = "fen-lua-tree";
    inherit version;
    src = ../.;

    nativeBuildInputs = [
      buildPkgs.coreutils
      buildPkgs.findutils
      buildPkgs.gnused
      buildPkgs.lua54Packages.fennel
      buildPkgs.zip
    ];

    buildPhase = ''
      runHook preBuild
      mkdir -p build
      FENNEL=${buildPkgs.lua54Packages.fennel}/bin/fennel \
      FENNEL_LUA=${runtimeFennel}/share/lua/5.4/fennel.lua \
      DKJSON_LUA=${dkjson}/share/lua/5.4/dkjson.lua \
      LUASOCKET_SRC=${luaSocketSrc}/src \
      LUAROCKS_SRC=${luarocks54}/share/lua/5.4/luarocks \
      ZIPCMD=${buildPkgs.zip}/bin/zip \
      FEN_ZIP_OUT=$PWD/build/fen-lua.zip \
      FEN_VERSION=${lib.escapeShellArg versionInfo.version} \
      FEN_GIT_REV=${lib.escapeShellArg versionInfo.gitRev} \
      FEN_GIT_SHORT=${lib.escapeShellArg versionInfo.gitShortRev} \
      FEN_DIRTY=${if versionInfo.dirty then "true" else "false"} \
      FEN_BUILD_SOURCE=${lib.escapeShellArg versionInfo.source} \
      FEN_LAST_MODIFIED=${lib.escapeShellArg versionInfo.lastModified} \
      FEN_BUILD_SYSTEM=${lib.escapeShellArg versionInfo.buildSystem} \
      FEN_TARGET_SYSTEM=${lib.escapeShellArg targetSystem} \
      ARTIFACT_SYSTEM=${lib.escapeShellArg artifactSystem} \
        sh scripts/build/package-lua-tree.sh build/lua-tree
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/share/lua/5.4" "$out/share/fen/bin"
      cp -R build/lua-tree/. "$out/share/lua/5.4/"
      install -Dm644 build/fen-lua.zip "$out/share/fen/fen-lua.zip"
      install -Dm644 packages/fen/bin/fen.lua "$out/share/fen/bin/fen.lua"
      runHook postInstall
    '';

    meta.description = "Compiled Lua module tree embedded by the fen binary";
  };

  artifacts = rec {
    fenBinary = targetPkgs.stdenv.mkDerivation {
      pname = "fen";
      inherit version;
      src = ../.;

      nativeBuildInputs = [
        buildPkgs.coreutils
        buildPkgs.perl
        buildPkgs.removeReferencesTo
      ];

      buildInputs = [ fenBinaryLua kubazipStatic fenCurlStatic fenOpenSSLStatic.dev fenOpenSSLStatic.out ];
      dontUnpack = true;
      dontStrip = true;
      dontFixup = true;

      buildPhase = ''
        runHook preBuild

        ${ccSetup}
        mkdir -p build
        cp ${luaTree}/share/fen/fen-lua.zip build/fen-lua.zip
        cp ${../packages/fen/fen.c} build/fen.c
        export PKG_CONFIG_PATH=${fenCurlStatic.dev}/lib/pkgconfig:${fenCurlStatic.out}/lib/pkgconfig:${fenOpenSSLStatic.dev}/lib/pkgconfig:''${PKG_CONFIG_PATH:-}
        curl_static_libs="$(${pkgConfig} --static --libs libcurl | sed 's/ -ldl//g')"
        $CC -O2 -Wall -static \
          -I${fenBinaryLua}/include \
          -I${kubazipStatic.dev}/include \
          build/fen.c \
          ${fenBinaryObjects}/*.o \
          -L${fenBinaryLua}/lib -L${kubazipStatic}/lib \
          -Wl,-Bstatic -lzip -llua $curl_static_libs \
          -lm \
          -o build/fen
        cat build/fen-lua.zip >> build/fen
        chmod +x build/fen

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        install -Dm755 build/fen "$out/bin/fen"
        cp "$out/bin/fen" "$out/bin/fen-${version}-${artifactSystem}"
        remove-references-to -t ${fenBinaryLua} "$out/bin/fen" "$out/bin/fen-${version}-${artifactSystem}"
        # Nix's link wrapper can leave dead store-path strings in the ELF string
        # table. Rewrite them in place, keeping the byte length stable so the
        # appended ZIP offsets remain valid.
        perl -0pi -e 's#/nix/store#/no-/store#g' \
          "$out/bin/fen" "$out/bin/fen-${version}-${artifactSystem}"
        runHook postInstall
      '';

      meta = {
        description = "Single-file prototype of the fen CLI with embedded Lua ZIP archive";
        mainProgram = "fen";
      };
    };

    scratchImage = import ./docker.nix {
      inherit targetPkgs version artifactSystem dockerArchitecture fenBinary;
    };

    checks = import ./checks.nix {
      inherit pkgs targetPkgs buildPkgs buildLuaPkgs version artifactSystem qemu fenBinary;
    };
  };
in
artifacts
