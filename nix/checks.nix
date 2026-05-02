{
  pkgs,
  targetPkgs,
  buildPkgs,
  buildLuaPkgs,
  version,
  artifactSystem,
  qemu,
  fenSingle,
  distTree,
}:

let
  singleLibPath = "${targetPkgs.curl.out}/lib:${targetPkgs.glibc}/lib";
  singleRun = "${targetPkgs.stdenv.cc.bintools.dynamicLinker} --argv0 ${fenSingle}/bin/fen --library-path ${singleLibPath} ${fenSingle}/bin/fen";
in
{
  singleSmoke = targetPkgs.runCommand "fen-${version}-${artifactSystem}-single-smoke"
    { nativeBuildInputs = [ buildPkgs.coreutils ]; }
    ''
      ${singleRun} --help > "$out"
    '';

  singleDevSmoke = targetPkgs.runCommand "fen-${version}-${artifactSystem}-single-dev-smoke"
    { nativeBuildInputs = [ buildPkgs.coreutils ]; }
    ''
      ${singleRun} \
        --dev-path ${../tests/fixtures/dev-path-sentinel} \
        --help > "$out"
      grep -q DEV-PATH-OK "$out"
    '';

  singleExtRootSmoke = targetPkgs.runCommand "fen-${version}-${artifactSystem}-single-ext-root-smoke"
    { nativeBuildInputs = [ buildPkgs.coreutils ]; }
    ''
      ${singleRun} \
        --dev-path ${../tests/fixtures/extension-root-sentinel/fen-main-stub} \
        --extension-root ${../tests/fixtures/extension-root-sentinel} \
        > "$out"
      grep -q EXT-ROOT-OK "$out"
    '';

  singleNativeSmoke = targetPkgs.runCommand "fen-${version}-${artifactSystem}-single-native-smoke"
    { nativeBuildInputs = [ buildPkgs.coreutils ]; }
    ''
      ${singleRun} \
        --dev-path ${../tests/fixtures/single-native-smoke} \
        > "$out"
      grep -q SINGLE-NATIVE-SMOKE-OK "$out"
    '';

  singleNoStoreRefs = targetPkgs.runCommand "fen-${version}-${artifactSystem}-single-no-store-refs"
    { nativeBuildInputs = [ buildPkgs.binutils buildPkgs.coreutils buildPkgs.gnugrep ]; }
    ''
      if strings ${fenSingle}/bin/fen | grep -F /nix/store > refs.txt; then
        cat refs.txt >&2
        exit 1
      fi
      touch "$out"
    '';

  singleDynamicDeps = targetPkgs.runCommand "fen-${version}-${artifactSystem}-single-dynamic-deps"
    { nativeBuildInputs = [ buildPkgs.coreutils buildPkgs.gnugrep ]; }
    ''
      ${buildPkgs.glibc.bin}/bin/ldd ${fenSingle}/bin/fen > "$out"
      if grep -E 'liblua|libzip|libcurl|libssl|libcrypto|cjson|termbox2|fen_http|fen_process|posix|socket' "$out"; then
        echo "forbidden dynamic dependency in fenSingle" >&2
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
      cat > fen-single-run <<'EOF'
#!/bin/sh
exec ${singleRun} "$@"
EOF
      chmod +x fen-single-run
      FEN_BIN=$PWD/fen-single-run checkout/bin/fen-dev --help > "$out"
      grep -q BIN-FEN-DEV-OK "$out"
    '';

  singleQemuSmoke = pkgs.runCommand "fen-${version}-${artifactSystem}-single-qemu-smoke"
    { nativeBuildInputs = [ pkgs.coreutils pkgs.pkgsStatic.qemu-user ]; }
    ''
      target_ld=$(echo ${targetPkgs.stdenv.cc.bintools.dynamicLinker})
      target_lib_path=${targetPkgs.curl.out}/lib:${targetPkgs.glibc}/lib
      ${pkgs.pkgsStatic.qemu-user}/bin/${qemu} \
        "$target_ld" --argv0 ${fenSingle}/bin/fen \
        --library-path "$target_lib_path" \
        ${fenSingle}/bin/fen --help > "$out"
      ${pkgs.pkgsStatic.qemu-user}/bin/${qemu} \
        "$target_ld" --argv0 ${fenSingle}/bin/fen \
        --library-path "$target_lib_path" \
        ${fenSingle}/bin/fen \
        --dev-path ${../tests/fixtures/single-native-smoke} \
        >> "$out"
      grep -q SINGLE-NATIVE-SMOKE-OK "$out"
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
