{
  pkgs,
  targetPkgs,
  buildPkgs,
  buildLuaPkgs,
  version,
  artifactSystem,
  qemu,
  fenBinary,
  distTree,
}:

let
  fenBinaryLibPath = "${targetPkgs.curl.out}/lib:${targetPkgs.glibc}/lib";
  fenBinaryRun = "${targetPkgs.stdenv.cc.bintools.dynamicLinker} --argv0 ${fenBinary}/bin/fen --library-path ${fenBinaryLibPath} ${fenBinary}/bin/fen";
in
{
  fenSmoke = targetPkgs.runCommand "fen-${version}-${artifactSystem}-fen-smoke"
    { nativeBuildInputs = [ buildPkgs.coreutils ]; }
    ''
      ${fenBinaryRun} --help > "$out"
    '';

  fenDevSmoke = targetPkgs.runCommand "fen-${version}-${artifactSystem}-fen-dev-smoke"
    { nativeBuildInputs = [ buildPkgs.coreutils ]; }
    ''
      ${fenBinaryRun} \
        --dev-path ${../tests/fixtures/dev-path-sentinel} \
        --help > "$out"
      grep -q DEV-PATH-OK "$out"
    '';

  fenExtRootSmoke = targetPkgs.runCommand "fen-${version}-${artifactSystem}-fen-ext-root-smoke"
    { nativeBuildInputs = [ buildPkgs.coreutils ]; }
    ''
      ${fenBinaryRun} \
        --dev-path ${../tests/fixtures/extension-root-sentinel/fen-main-stub} \
        --extension-root ${../tests/fixtures/extension-root-sentinel} \
        > "$out"
      grep -q EXT-ROOT-OK "$out"
    '';

  fenNativeSmoke = targetPkgs.runCommand "fen-${version}-${artifactSystem}-fen-native-smoke"
    { nativeBuildInputs = [ buildPkgs.coreutils ]; }
    ''
      ${fenBinaryRun} \
        --dev-path ${../tests/fixtures/fen-native-smoke} \
        > "$out"
      grep -q FEN-NATIVE-SMOKE-OK "$out"
    '';

  fenExtBuildSmoke = targetPkgs.runCommand "fen-${version}-${artifactSystem}-fen-ext-build-smoke"
    { nativeBuildInputs = [ buildPkgs.coreutils buildPkgs.findutils ]; }
    ''
      mkdir ext rocks
      cat > ext/fen-ext-smoke-1-1.rockspec <<'EOF'
package = "fen-ext-smoke"
version = "1-1"
source = { url = "." }
build = { type = "builtin", modules = { ["fen_ext_smoke"] = "fen_ext_smoke.lua" } }
EOF
      echo 'return { ok = true }' > ext/fen_ext_smoke.lua
      FEN_ROCKS_TREE=$PWD/rocks ${fenBinaryRun} ext build $PWD/ext > "$out"
      test -f rocks/share/lua/5.4/fen_ext_smoke.lua
      if command -v luarocks >/dev/null 2>&1; then
        echo "fenExtBuildSmoke unexpectedly has system luarocks on PATH" >&2
        exit 1
      fi
    '';

  fenNoStoreRefs = targetPkgs.runCommand "fen-${version}-${artifactSystem}-fen-no-store-refs"
    { nativeBuildInputs = [ buildPkgs.binutils buildPkgs.coreutils buildPkgs.gnugrep ]; }
    ''
      if strings ${fenBinary}/bin/fen | grep -F /nix/store > refs.txt; then
        cat refs.txt >&2
        exit 1
      fi
      touch "$out"
    '';

  fenDynamicDeps = targetPkgs.runCommand "fen-${version}-${artifactSystem}-fen-dynamic-deps"
    { nativeBuildInputs = [ buildPkgs.coreutils buildPkgs.gnugrep ]; }
    ''
      ${buildPkgs.glibc.bin}/bin/ldd ${fenBinary}/bin/fen > "$out"
      if grep -E 'liblua|libzip|libcurl|libssl|libcrypto|cjson|termbox2|fen_http|fen_process|lfs|posix|socket' "$out"; then
        echo "forbidden dynamic dependency in fen" >&2
        exit 1
      fi
    '';

  fennelCheck = targetPkgs.runCommand "fen-${version}-${artifactSystem}-fennel-check"
    { nativeBuildInputs = [ buildLuaPkgs.fennel buildPkgs.findutils ]; }
    ''
      cd ${../.}
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
        buildLuaPkgs.luasocket
      ];
    }
    ''
      cp -R ${../.} source
      chmod -R u+w source
      cd source
      export HOME=$TMPDIR/home
      export XDG_STATE_HOME=$TMPDIR/state
      export XDG_CONFIG_HOME=$TMPDIR/config
      mkdir -p "$HOME" "$XDG_STATE_HOME" "$XDG_CONFIG_HOME"
      export LUA_INCDIR=${buildPkgs.lua5_4}/include
      export CURL_INCDIR=${buildPkgs.curl.dev}/include
      export CURL_LIBDIR=${buildPkgs.curl.out}/lib
      sh scripts/run-tests.sh
      touch "$out"
    '';

  binFenDevSmoke = targetPkgs.runCommand "fen-${version}-${artifactSystem}-bin-fen-dev-smoke"
    { nativeBuildInputs = [ buildPkgs.coreutils ]; }
    ''
      cp -R ${../.} checkout
      chmod -R u+w checkout
      sed -i 's/fen — minimal/BIN-FEN-DEV-OK fen — minimal/' \
        checkout/packages/fen/src/fen/main.fnl
      cat > fen-binary-run <<'EOF'
#!/bin/sh
exec ${fenBinaryRun} "$@"
EOF
      chmod +x fen-binary-run
      FEN_BIN=$PWD/fen-binary-run checkout/bin/fen-dev --help > "$out"
      grep -q BIN-FEN-DEV-OK "$out"
    '';

  fenQemuSmoke = pkgs.runCommand "fen-${version}-${artifactSystem}-fen-qemu-smoke"
    { nativeBuildInputs = [ pkgs.coreutils pkgs.pkgsStatic.qemu-user ]; }
    ''
      target_ld=$(echo ${targetPkgs.stdenv.cc.bintools.dynamicLinker})
      target_lib_path=${targetPkgs.curl.out}/lib:${targetPkgs.glibc}/lib
      ${pkgs.pkgsStatic.qemu-user}/bin/${qemu} \
        "$target_ld" --argv0 ${fenBinary}/bin/fen \
        --library-path "$target_lib_path" \
        ${fenBinary}/bin/fen --help > "$out"
      ${pkgs.pkgsStatic.qemu-user}/bin/${qemu} \
        "$target_ld" --argv0 ${fenBinary}/bin/fen \
        --library-path "$target_lib_path" \
        ${fenBinary}/bin/fen \
        --dev-path ${../tests/fixtures/fen-native-smoke} \
        >> "$out"
      grep -q FEN-NATIVE-SMOKE-OK "$out"
    '';

  distSmoke = targetPkgs.runCommand "fen-${version}-${artifactSystem}-dist-smoke"
    { nativeBuildInputs = [ buildPkgs.coreutils ]; }
    ''
      ${distTree}/opt/fen/bin/fen --help > "$out"
      ld_interp=$(echo ${targetPkgs.stdenv.cc.bintools.dynamicLinker})
      LUA_PATH="${distTree}/opt/fen/share/lua/5.4/?.lua;${distTree}/opt/fen/share/lua/5.4/?/init.lua;;" \
        ${distTree}/opt/fen/lib/$(basename "$ld_interp") \
        --library-path ${distTree}/opt/fen/lib \
        ${distTree}/opt/fen/libexec/lua \
        -e 'assert(require("fennel").dofile("${../tests/fixtures/fnl-extension}/init.fnl"))' \
        >> "$out"
    '';

  qemuSmoke = pkgs.runCommand "fen-${version}-${artifactSystem}-qemu-smoke"
    { nativeBuildInputs = [ pkgs.coreutils pkgs.pkgsStatic.qemu-user ]; }
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
        -e 'assert(require("fennel").dofile("${../tests/fixtures/fnl-extension}/init.fnl"))' \
        >> "$out"
    '';
}
