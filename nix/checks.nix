{
  pkgs,
  targetPkgs,
  buildPkgs,
  buildLuaPkgs,
  version,
  artifactSystem,
  qemu,
  fenBinary,
}:

let
  fenBinaryLibPath = "${targetPkgs.glibc}/lib";
  fenBinaryRun = "${targetPkgs.stdenv.cc.bintools.dynamicLinker} --argv0 ${fenBinary}/bin/fen --library-path ${fenBinaryLibPath} ${fenBinary}/bin/fen";
in
{
  fenSmoke = targetPkgs.runCommand "fen-${version}-${artifactSystem}-fen-smoke"
    { nativeBuildInputs = [ buildPkgs.coreutils ]; }
    ''
      ${fenBinaryRun} --help > "$out"
    '';

  fenOverlaySmoke = targetPkgs.runCommand "fen-${version}-${artifactSystem}-fen-overlay-smoke"
    { nativeBuildInputs = [ buildPkgs.coreutils ]; }
    ''
      ${fenBinaryRun} \
        --dev-path ${../tests/fixtures/dev-path-sentinel} \
        --help > "$out"
      grep -q DEV-PATH-OK "$out"

      ${fenBinaryRun} \
        --dev-path ${../tests/fixtures/extension-root-sentinel/fen-main-stub} \
        --extension-root ${../tests/fixtures/extension-root-sentinel} \
        >> "$out"
      grep -q EXT-ROOT-OK "$out"

      ${fenBinaryRun} \
        --dev-path ${../tests/fixtures/fen-native-smoke} \
        >> "$out"
      grep -q FEN-NATIVE-SMOKE-OK "$out"

      cp -R ${../.} checkout
      chmod -R u+w checkout
      sed -i 's/fen — minimal/BIN-FEN-DEV-OK fen — minimal/' \
        checkout/packages/fen/src/fen/main.fnl
      cat > fen-binary-run <<'EOF'
#!/bin/sh
exec ${fenBinaryRun} "$@"
EOF
      chmod +x fen-binary-run
      FEN_BIN=$PWD/fen-binary-run checkout/bin/fen-dev --help >> "$out"
      grep -q BIN-FEN-DEV-OK "$out"
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
      if grep -E 'liblua|libzip|libcurl|libssl|libcrypto|cjson|termbox2|fen_http|fen_process|fen_random|lfs|posix|socket' "$out"; then
        echo "forbidden dynamic dependency in fen" >&2
        exit 1
      fi
    '';

  fennelCheck = targetPkgs.runCommand "fen-${version}-${artifactSystem}-fennel-check"
    { nativeBuildInputs = [ buildLuaPkgs.fennel buildPkgs.findutils ]; }
    ''
      cd ${../.}
      ${buildLuaPkgs.fennel}/bin/fennel scripts/fennel-check.fnl
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

  fenQemuSmoke = pkgs.runCommand "fen-${version}-${artifactSystem}-fen-qemu-smoke"
    { nativeBuildInputs = [ pkgs.coreutils pkgs.pkgsStatic.qemu-user ]; }
    ''
      target_ld=$(echo ${targetPkgs.stdenv.cc.bintools.dynamicLinker})
      target_lib_path=${targetPkgs.glibc}/lib
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

}
