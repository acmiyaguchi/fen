{
  pkgs,
  targetPkgs,
  buildPkgs,
  buildLuaPkgs,
  version,
  artifactSystem,
  qemu,
  fenBinary,
  dynamicLinker,
  static ? false,
  manylinuxGlibcVersion ? null,
}:

let
  fenBinaryLibPath = if static then null else "${targetPkgs.glibc}/lib";
  qemuDynamicLinker = if static then null else "${targetPkgs.glibc}/lib/${builtins.baseNameOf dynamicLinker}";
  fenBinaryRun = if static
    then "${fenBinary}/bin/fen"
    else "${targetPkgs.stdenv.cc.bintools.dynamicLinker} --argv0 ${fenBinary}/bin/fen --library-path ${fenBinaryLibPath} ${fenBinary}/bin/fen";
  # Only cross targets expose fenQemuSmoke; native targets have qemu = null and
  # should use fenSmoke / fenOverlaySmoke directly.
  fenQemuRun = assert qemu != null; if static
    then "${pkgs.pkgsStatic.qemu-user}/bin/${qemu} ${fenBinary}/bin/fen"
    else ''${pkgs.pkgsStatic.qemu-user}/bin/${qemu} \
        "${qemuDynamicLinker}" --argv0 ${fenBinary}/bin/fen \
        --library-path "${fenBinaryLibPath}" \
        ${fenBinary}/bin/fen'';
in
{
  fenSmoke = targetPkgs.runCommand "fen-${version}-${artifactSystem}-fen-smoke"
    { nativeBuildInputs = [ buildPkgs.coreutils ]; }
    ''
      ${fenBinaryRun} --help > "$out"

      export HOME=$TMPDIR/home
      export XDG_STATE_HOME=$TMPDIR/state
      export XDG_CONFIG_HOME=$TMPDIR/config
      mkdir -p "$HOME" "$XDG_STATE_HOME" "$XDG_CONFIG_HOME"
      env -u FEN_EXTENSION_ROOT \
          -u FEN_FIRST_PARTY_EXTENSIONS_PATH \
          -u FEN_EXTENSIONS_PATH \
          ${fenBinaryRun} \
            --dev-path ${../packages/testing/tests/fixtures/embedded-first-party-smoke} \
            >> "$out"
      grep -q EMBEDDED-FIRST-PARTY-OK "$out"
    '';

  fenMockProviderSmoke = targetPkgs.runCommand "fen-${version}-${artifactSystem}-fen-mock-provider-smoke"
    { nativeBuildInputs = [ buildPkgs.coreutils buildLuaPkgs.fennel buildLuaPkgs.luasocket ]; }
    ''
      cp -R ${../.} source
      chmod -R u+w source
      cd source
      export HOME=$TMPDIR/home
      export XDG_STATE_HOME=$TMPDIR/state
      export XDG_CONFIG_HOME=$TMPDIR/config
      mkdir -p "$HOME" "$XDG_STATE_HOME" "$XDG_CONFIG_HOME"
      cat > fen-binary-run <<'EOF'
#!/bin/sh
exec ${fenBinaryRun} "$@"
EOF
      chmod +x fen-binary-run
      FEN_BIN=$PWD/fen-binary-run sh scripts/smoke-mock.sh > "$out"
      grep -q 'mock smoke: 4 pass, 0 fail' "$out"
    '';

  fenOverlaySmoke = targetPkgs.runCommand "fen-${version}-${artifactSystem}-fen-overlay-smoke"
    { nativeBuildInputs = [ buildPkgs.coreutils ]; }
    ''
      ${fenBinaryRun} \
        --dev-path ${../packages/testing/tests/fixtures/dev-path-sentinel} \
        --help > "$out"
      grep -q DEV-PATH-OK "$out"

      ${fenBinaryRun} \
        --dev-path ${../packages/testing/tests/fixtures/extension-root-sentinel/fen-main-stub} \
        --extension-root ${../packages/testing/tests/fixtures/extension-root-sentinel} \
        >> "$out"
      grep -q EXT-ROOT-OK "$out"

      ${fenBinaryRun} \
        --dev-path ${../packages/testing/tests/fixtures/fen-native-smoke} \
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
      FEN_BIN=$PWD/fen-binary-run checkout/scripts/fen-dev --help >> "$out"
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
    { nativeBuildInputs = [ pkgs.binutils pkgs.coreutils pkgs.gnugrep ]; }
    ''
      if ${pkgs.binutils}/bin/strings ${fenBinary}/bin/fen | grep -F /nix/store > refs.txt; then
        cat refs.txt >&2
        exit 1
      fi
      touch "$out"
    '';

  fenDynamicDeps = targetPkgs.runCommand "fen-${version}-${artifactSystem}-fen-dynamic-deps"
    { nativeBuildInputs = [ pkgs.binutils pkgs.coreutils pkgs.gnugrep pkgs.gnused ]; }
    (if static then ''
      ${pkgs.binutils}/bin/readelf -l ${fenBinary}/bin/fen > program-headers.txt
      if grep -F INTERP program-headers.txt; then
        echo "static fen unexpectedly has an ELF interpreter" >&2
        exit 1
      fi
      if ${pkgs.binutils}/bin/readelf -d ${fenBinary}/bin/fen > dynamic-section.txt 2>/dev/null && grep -F NEEDED dynamic-section.txt; then
        echo "static fen unexpectedly has dynamic NEEDED entries" >&2
        exit 1
      fi
      touch "$out"
    '' else ''
      ${pkgs.binutils}/bin/readelf -d ${fenBinary}/bin/fen > dynamic-section.txt
      grep -F NEEDED dynamic-section.txt > "$out" || true
      sed -n 's/.*Shared library: \[\(.*\)\].*/\1/p' "$out" > needed-libs.txt
      allowed='libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 ld-linux-armhf.so.3'
      while IFS= read -r lib; do
        case " $allowed " in
          *" $lib "*) ;;
          *)
            echo "unexpected dynamic dependency in fen: $lib" >&2
            cat needed-libs.txt >&2
            exit 1
            ;;
        esac
      done < needed-libs.txt

      glibc_floor='${if manylinuxGlibcVersion == null then "" else manylinuxGlibcVersion}'
      if [ -n "$glibc_floor" ]; then
        ${pkgs.binutils}/bin/strings ${fenBinary}/bin/fen \
          | grep -ao 'GLIBC_[0-9][0-9.]*' \
          | sort -Vu > glibc-versions.txt || true
        max_glibc=$(tail -n 1 glibc-versions.txt || true)
        if [ -n "$max_glibc" ]; then
          allowed="GLIBC_$glibc_floor"
          newest=$(printf '%s\n%s\n' "$allowed" "$max_glibc" | sort -Vu | tail -n 1)
          if [ "$newest" != "$allowed" ]; then
            echo "fen requires $max_glibc, above configured GLIBC_$glibc_floor floor" >&2
            cat glibc-versions.txt >&2
            exit 1
          fi
        fi
        {
          echo
          echo "GLIBC symbol versions:"
          cat glibc-versions.txt
        } >> "$out"
      fi
    '');

  fennelCheck = targetPkgs.runCommand "fen-${version}-${artifactSystem}-fennel-check"
    { nativeBuildInputs = [ buildLuaPkgs.fennel buildPkgs.findutils ]; }
    ''
      cd ${../.}
      ${buildLuaPkgs.fennel}/bin/fennel scripts/fennel-check.fnl
      touch "$out"
    '';

  docs = targetPkgs.runCommand "fen-${version}-${artifactSystem}-docs"
    { nativeBuildInputs = [ buildLuaPkgs.fennel buildPkgs.findutils buildPkgs.graphviz ]; }
    ''
      cp -R ${../.} source
      chmod -R u+w source
      cd source
      ${buildLuaPkgs.fennel}/bin/fennel scripts/gen-docs.fnl
      ${buildLuaPkgs.fennel}/bin/fennel scripts/gen-graphs.fnl --kind all
      ${buildLuaPkgs.fennel}/bin/fennel scripts/gen-static-docs.fnl
      test -s docs/graphs/modules.dot
      test -s docs/graphs/modules.svg
      test -s docs/graphs/modules-clustered.dot
      test -s docs/graphs/modules-clustered.svg
      test -s docs/graphs/subsystems.dot
      test -s docs/graphs/subsystems.svg
      test -s docs/generated/graphs/summary.md
      test -s docs/generated/graphs/extensions/tui.dot
      test -s docs/generated/graphs/extensions/tui.svg
      test -s docs/generated/html/index.html
      cp -R docs/generated "$out"
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
      ${fenQemuRun} --help > "$out"
      ${fenQemuRun} \
        --dev-path ${../packages/testing/tests/fixtures/fen-native-smoke} \
        >> "$out"
      grep -q FEN-NATIVE-SMOKE-OK "$out"

      export HOME=$TMPDIR/home
      export XDG_STATE_HOME=$TMPDIR/state
      export XDG_CONFIG_HOME=$TMPDIR/config
      mkdir -p "$HOME" "$XDG_STATE_HOME" "$XDG_CONFIG_HOME"
      env -u FEN_EXTENSION_ROOT \
          -u FEN_FIRST_PARTY_EXTENSIONS_PATH \
          -u FEN_EXTENSIONS_PATH \
          ${fenQemuRun} \
            --dev-path ${../packages/testing/tests/fixtures/embedded-first-party-smoke} \
            >> "$out"
      grep -q EMBEDDED-FIRST-PARTY-OK "$out"
    '';

}
