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
  glibcFloorZigTargetFor,
  static ? false,
  glibcFloorVersion ? "2.17",
}:

let
  lib = pkgs.lib;
  buildPkgs = targetPkgs.buildPackages;
  lua = targetPkgs.lua5_4;
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
  # Dynamic release artifacts can opt into a minimum glibc floor.
  # In that mode every native object linked into fen is built with Zig's
  # old-glibc target: Lua, fen-owned C, kubazip, OpenSSL, curl, and the final
  # executable link.
  # Do not add compatibility shims for newer glibc symbols here; if a static
  # dependency needs a newer symbol, build that dependency with this same CC.
  glibcFloorBuild = (!static) && glibcFloorVersion != null;
  glibcFloorZigTarget = if glibcFloorBuild then glibcFloorZigTargetFor targetSystem glibcFloorVersion else null;
  glibcFloorAutoconfHost = if glibcFloorBuild then targetPkgs.stdenv.hostPlatform.config else null;
  # Zig accepts CPU names such as cortex_a7 for ARM, but not GCC's
  # -march=armv7-a spelling that Nixpkgs can feed into dependency builds.
  glibcFloorCc = if glibcFloorBuild then buildPkgs.writeShellScript "fen-glibc-floor-cc" ''
    args=()
    for arg in "$@"; do
      case "$arg" in
        -march=armv7-a) args+=("-mcpu=cortex_a7") ;;
        *) args+=("$arg") ;;
      esac
    done
    exec ${buildPkgs.zig}/bin/zig cc -target ${glibcFloorZigTarget} "''${args[@]}"
  '' else null;
  glibcFloorCxx = if glibcFloorBuild then buildPkgs.writeShellScript "fen-glibc-floor-cxx" ''
    args=()
    for arg in "$@"; do
      case "$arg" in
        -march=armv7-a) args+=("-mcpu=cortex_a7") ;;
        *) args+=("$arg") ;;
      esac
    done
    exec ${buildPkgs.zig}/bin/zig c++ -target ${glibcFloorZigTarget} "''${args[@]}"
  '' else null;
  ccSetup = lib.optionalString glibcFloorBuild ''
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
    export CC='${glibcFloorCc}'
    export CXX='${glibcFloorCxx}'
  '';
  glibcFloorDependencyAttrs = old: lib.optionalAttrs glibcFloorBuild {
    preConfigure = (old.preConfigure or "") + ''

      ${ccSetup}
    '';
  };
  kubazipStatic = targetPkgs.kubazip.overrideAttrs (old: {
    cmakeFlags = (old.cmakeFlags or []) ++ [ "-DBUILD_SHARED_LIBS=OFF" ];
    # The glibc-floor test executables are linked for /lib*/ld-linux rather
    # than the Nix store loader, so CTest cannot run them in the sandbox.
    # Final fen smoke tests still exercise the embedded kubazip path.
    doCheck = if glibcFloorBuild then false else (old.doCheck or true);
  } // glibcFloorDependencyAttrs old);
  fenOpenSSLStatic = targetPkgs.openssl.overrideAttrs (old: {
    configureFlags = (old.configureFlags or []) ++ [ "no-shared" ];
    # These overrides are only linked into the fen executable; upstream tests
    # are expensive for cross/static release builds and covered by fen smoke.
    doCheck = false;
  } // glibcFloorDependencyAttrs old);
  fenCurlStatic = targetPkgs.curl.overrideAttrs (old: {
    buildInputs = (old.buildInputs or []) ++ [ fenOpenSSLStatic ];
    doCheck = false;
    configureFlags = (old.configureFlags or []) ++ lib.optionals glibcFloorBuild [
      "--host=${glibcFloorAutoconfHost}"
    ] ++ [
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
  } // glibcFloorDependencyAttrs old);
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

    nativeBuildInputs = [ buildPkgs.gnumake ] ++ lib.optionals glibcFloorBuild [ buildPkgs.zig ];

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

    nativeBuildInputs = [ buildPkgs.coreutils ] ++ lib.optionals glibcFloorBuild [ buildPkgs.zig ];
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
      ] ++ lib.optionals glibcFloorBuild [ buildPkgs.zig ];

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
        $CC -O2 -Wall ${lib.optionalString static "-static"} ${lib.optionalString glibcFloorBuild "-pie"} \
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
      inherit pkgs targetPkgs buildPkgs buildLuaPkgs version artifactSystem qemu fenBinary dynamicLinker static glibcFloorVersion;
    };

    devShell = import ./dev-shell.nix {
      inherit targetPkgs lua devLuaPackages testRocks;
    };
  };
in
artifacts
