{
  pkgs,
  targetPkgs,
  version,
  versionInfo,
  targetSystem,
  artifactSystemFor,
  staticArtifactSystemFor,
  dockerArchitectureFor,
  qemuFor,
  dynamicLinkerFor,
  manylinuxZigTargetFor,
  static ? false,
  manylinuxGlibcVersion ? "2.17",
}:

let
  lib = pkgs.lib;
  buildPkgs = targetPkgs.buildPackages;
  lua = targetPkgs.lua5_4;
  kubazipStatic = targetPkgs.kubazip.overrideAttrs (old: {
    cmakeFlags = (old.cmakeFlags or []) ++ [ "-DBUILD_SHARED_LIBS=OFF" ];
  });
  fenOpenSSLStatic = targetPkgs.openssl.overrideAttrs (old: {
    configureFlags = (old.configureFlags or []) ++ [ "no-shared" ];
    # These overrides are only linked into the fen executable; upstream tests
    # are expensive for cross/static release builds and covered by fen smoke.
    doCheck = false;
  });
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
  });
  luaPkgs = targetPkgs.lua54Packages;
  buildLuaPkgs = buildPkgs.lua54Packages;
  runtimeLuaPkgs = if static then buildLuaPkgs else luaPkgs;
  luarocks54 = runtimeLuaPkgs.luarocks or (targetPkgs.luarocks.override { lua = lua; });
  devLuaPackages = with luaPkgs; [ lua-cjson luasocket ];
  testRocks = with luaPkgs; [ busted ];
  artifactSystem = if static then staticArtifactSystemFor targetSystem else artifactSystemFor targetSystem;
  dockerArchitecture = dockerArchitectureFor targetSystem;
  qemu = qemuFor targetSystem;
  dynamicLinker = if static then null else dynamicLinkerFor targetSystem;
  manylinux = (!static) && manylinuxGlibcVersion != null;
  manylinuxZigTarget = if manylinux then manylinuxZigTargetFor targetSystem manylinuxGlibcVersion else null;
  manylinuxCc = if manylinux then "${buildPkgs.zig}/bin/zig cc -target ${manylinuxZigTarget}" else null;
  ccSetup = lib.optionalString manylinux ''
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
    export CC='${manylinuxCc}'
  '';
  luaMyCFlags = if static then "-DLUA_USE_POSIX" else "-DLUA_USE_LINUX";
  luaMyLibs = if static then "-lm" else "-lm -ldl";
  runtimeFennel = buildPkgs.lua54Packages.fennel;
  pkgConfig = "${buildPkgs.pkg-config}/bin/${targetPkgs.stdenv.cc.targetPrefix}pkg-config";
  luaCjsonSrc = runtimeLuaPkgs.lua-cjson.src;
  luaLfsSrc = runtimeLuaPkgs.luafilesystem.src;
  dkjson = runtimeLuaPkgs.dkjson;

  fenBinaryLua = targetPkgs.stdenv.mkDerivation {
    pname = "fen-binary-lua";
    version = lua.version or "5.4";
    src = targetPkgs.lua5_4.src;

    nativeBuildInputs = [ buildPkgs.gnumake ] ++ lib.optionals manylinux [ buildPkgs.zig ];

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

    nativeBuildInputs = [ buildPkgs.coreutils ] ++ lib.optionals manylinux [ buildPkgs.zig ];
    buildInputs = [ fenBinaryLua fenCurlStatic ];

    dontConfigure = true;
    dontFixup = true;

    buildPhase = ''
      runHook preBuild
      ${ccSetup}
      mkdir -p obj cjson-src lfs-src
      cp -R ${luaCjsonSrc}/. cjson-src/
      cp -R ${luaLfsSrc}/. lfs-src/
      chmod -R u+w cjson-src lfs-src

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

      ${lib.optionalString manylinux ''
      cat > fen_glibc_compat.c <<'EOF'
      #include <errno.h>
      #include <fcntl.h>
      #include <stdarg.h>
      #include <stdio.h>
      #include <stdlib.h>
      #include <sys/syscall.h>
      #include <unistd.h>
      long int __isoc23_strtol(const char *nptr, char **endptr, int base) { return strtol(nptr, endptr, base); }
      unsigned long int __isoc23_strtoul(const char *nptr, char **endptr, int base) { return strtoul(nptr, endptr, base); }
      long long int __isoc23_strtoll(const char *nptr, char **endptr, int base) { return strtoll(nptr, endptr, base); }
      unsigned long long int __isoc23_strtoull(const char *nptr, char **endptr, int base) { return strtoull(nptr, endptr, base); }
      float __isoc23_strtof(const char *nptr, char **endptr) { return strtof(nptr, endptr); }
      double __isoc23_strtod(const char *nptr, char **endptr) { return strtod(nptr, endptr); }
      long double __isoc23_strtold(const char *nptr, char **endptr) { return strtold(nptr, endptr); }
      int __isoc23_vsscanf(const char *str, const char *format, va_list ap) { return vsscanf(str, format, ap); }
      int __isoc23_vfscanf(FILE *stream, const char *format, va_list ap) { return vfscanf(stream, format, ap); }
      int __isoc23_vscanf(const char *format, va_list ap) { return vscanf(format, ap); }
      int __isoc23_sscanf(const char *str, const char *format, ...) { va_list ap; va_start(ap, format); int rc = vsscanf(str, format, ap); va_end(ap); return rc; }
      int __isoc23_fscanf(FILE *stream, const char *format, ...) { va_list ap; va_start(ap, format); int rc = vfscanf(stream, format, ap); va_end(ap); return rc; }
      int __isoc23_scanf(const char *format, ...) { va_list ap; va_start(ap, format); int rc = vscanf(format, ap); va_end(ap); return rc; }
      int fcntl64(int fd, int cmd, ...) {
        long arg = 0;
        switch (cmd) {
        #ifdef F_GETFD
          case F_GETFD:
        #endif
        #ifdef F_GETFL
          case F_GETFL:
        #endif
        #ifdef F_GETOWN
          case F_GETOWN:
        #endif
            break;
          default: {
            va_list ap;
            va_start(ap, cmd);
            arg = va_arg(ap, long);
            va_end(ap);
            break;
          }
        }
      #ifdef SYS_fcntl64
        return (int)syscall(SYS_fcntl64, fd, cmd, arg);
      #elif defined(SYS_fcntl)
        return (int)syscall(SYS_fcntl, fd, cmd, arg);
      #else
        errno = ENOSYS;
        return -1;
      #endif
      }
EOF
      $CC -std=gnu17 -O2 -Wall -c fen_glibc_compat.c -o obj/fen_glibc_compat.o
      ''}

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

  luaTree = targetPkgs.stdenv.mkDerivation {
    pname = "fen-lua-tree";
    inherit version;
    src = ../.;

    nativeBuildInputs = [ buildPkgs.lua54Packages.fennel ];

    buildPhase = ''
      runHook preBuild
      ${buildPkgs.lua54Packages.fennel}/bin/fennel scripts/fennel-build.fnl
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
        buildPkgs.patchelf
        buildPkgs.perl
        buildPkgs.removeReferencesTo
        buildPkgs.zip
      ] ++ lib.optionals manylinux [ buildPkgs.zig ];

      buildInputs = [ fenBinaryLua kubazipStatic fenCurlStatic fenOpenSSLStatic.dev fenOpenSSLStatic.out ];
      dontUnpack = true;
      dontStrip = true;
      dontFixup = static;

      buildPhase = ''
        runHook preBuild

        ${ccSetup}
        mkdir -p archive-root build
        cp -R ${luaTree}/share/lua/5.4/. archive-root/
        cp -R ${luarocks54}/share/lua/5.4/luarocks archive-root/luarocks
        cp -R ${dkjson}/share/lua/5.4/. archive-root/

        chmod -R u+rwX,go+rX archive-root
        find archive-root -exec touch -h -d @1 {} +
        (cd archive-root && find . -type f -print | sort | sed 's#^./##' \
          | zip -q -X -9 ../build/fen-lua.zip -@)

        cp ${../packages/fen/fen.c} build/fen.c
        export PKG_CONFIG_PATH=${fenCurlStatic.dev}/lib/pkgconfig:${fenCurlStatic.out}/lib/pkgconfig:${fenOpenSSLStatic.dev}/lib/pkgconfig:''${PKG_CONFIG_PATH:-}
        curl_static_libs="$(${pkgConfig} --static --libs libcurl | sed 's/ -ldl//g')"
        $CC -O2 -Wall ${lib.optionalString static "-static"} \
          -I${fenBinaryLua}/include \
          -I${kubazipStatic.dev}/include \
          build/fen.c \
          ${fenBinaryObjects}/*.o \
          -L${fenBinaryLua}/lib -L${kubazipStatic}/lib \
          -Wl,-Bstatic -lzip -llua $curl_static_libs ${lib.optionalString (!static) "-Wl,-Bdynamic"} \
          ${if static then "-lm" else "-lm -ldl"} \
          -o build/fen
        ${lib.optionalString (!static) ''
        if [ -n "${dynamicLinker}" ]; then
          patchelf --set-interpreter ${dynamicLinker} build/fen
        fi
        patchelf --remove-rpath build/fen || true
        ''}
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

    scratchImage = import ./docker.nix {
      inherit targetPkgs version artifactSystem dockerArchitecture fenBinary dynamicLinker;
    };

    checks = import ./checks.nix {
      inherit pkgs targetPkgs buildPkgs buildLuaPkgs version artifactSystem qemu fenBinary dynamicLinker static manylinuxGlibcVersion;
    };

    devShell = import ./dev-shell.nix {
      inherit targetPkgs lua devLuaPackages testRocks;
    };
  };
in
artifacts
