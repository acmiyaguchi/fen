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
  # The N900 variant feeds extra CPU/FPU flags through dependency and final
  # compiles; the base static build needs no CC tuning.
  ccSetup = lib.optionalString (extraCcFlags != []) ''
    export NIX_CFLAGS_COMPILE="''${NIX_CFLAGS_COMPILE:-} ${extraCcFlagsString}"
    export CFLAGS="''${CFLAGS:-} ${extraCcFlagsString}"
    export CXXFLAGS="''${CXXFLAGS:-} ${extraCcFlagsString}"
  '';
  tunedDependencyAttrs = old: lib.optionalAttrs (extraCcFlags != []) {
    preConfigure = (old.preConfigure or "") + ''

      ${ccSetup}
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
  fenCurlStatic = targetPkgs.curl.overrideAttrs (old: {
    buildInputs = (old.buildInputs or []) ++ [ fenOpenSSLStatic ];
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
      ${ccSetup}
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

      for src in \
        luasocket.c timeout.c buffer.c io.c auxiliar.c compat.c options.c \
        inet.c usocket.c except.c select.c tcp.c udp.c mime.c \
        unixstream.c unixdgram.c unix.c serial.c; do
        base=''${src%.c}
        $CC -O2 -Wall -DLUASOCKET_NODEBUG \
          -I${fenBinaryLua}/include -Iluasocket-src/src \
          -c "luasocket-src/src/$src" \
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

    nativeBuildInputs = [ buildPkgs.lua54Packages.fennel ];

    buildPhase = ''
      runHook preBuild
      ${buildPkgs.lua54Packages.fennel}/bin/fennel scripts/build/fennel-build.fnl
      mkdir -p packages/fen/dist/fen
      cat > packages/fen/dist/fen/version.lua <<'EOF'
return {
  version = "${versionInfo.version}",
  gitRev = "${versionInfo.gitRev}",
  gitShortRev = "${versionInfo.gitShortRev}",
  dirty = ${if versionInfo.dirty then "true" else "false"},
  source = "${versionInfo.source}",
  lastModified = "${versionInfo.lastModified}",
  buildSystem = "${versionInfo.buildSystem}",
  targetSystem = "${targetSystem}",
}
EOF
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p "$out/share/lua/5.4" "$out/share/fen/bin"

      find packages extensions -type d -name dist -prune -print | sort | while read -r d; do
        cp -R "$d"/. "$out/share/lua/5.4/"
      done

      install -Dm644 packages/fen/bin/fen.lua "$out/share/fen/bin/fen.lua"
      install -Dm644 ${runtimeFennel}/share/lua/5.4/fennel.lua \
        "$out/share/lua/5.4/fennel.lua"

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
        buildPkgs.findutils
        buildPkgs.perl
        buildPkgs.removeReferencesTo
        buildPkgs.zip
      ];

      buildInputs = [ fenBinaryLua kubazipStatic fenCurlStatic fenOpenSSLStatic.dev fenOpenSSLStatic.out ];
      dontUnpack = true;
      dontStrip = true;
      dontFixup = true;

      buildPhase = ''
        runHook preBuild

        ${ccSetup}
        mkdir -p archive-root build
        cp -R ${luaTree}/share/lua/5.4/. archive-root/
        cp -R ${luarocks54}/share/lua/5.4/luarocks archive-root/luarocks
        cp -R ${dkjson}/share/lua/5.4/. archive-root/
        cp ${luaSocketSrc}/src/socket.lua ${luaSocketSrc}/src/mime.lua ${luaSocketSrc}/src/ltn12.lua archive-root/
        mkdir -p archive-root/socket
        cp ${luaSocketSrc}/src/http.lua \
           ${luaSocketSrc}/src/url.lua \
           ${luaSocketSrc}/src/tp.lua \
           ${luaSocketSrc}/src/ftp.lua \
           ${luaSocketSrc}/src/headers.lua \
           ${luaSocketSrc}/src/smtp.lua \
           archive-root/socket/

        chmod -R u+rwX,go+rX archive-root
        find archive-root -exec touch -h -d @1 {} +
        (cd archive-root && find . -type f -print | sort | sed 's#^./##' \
          | zip -q -X -9 ../build/fen-lua.zip -@)

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
