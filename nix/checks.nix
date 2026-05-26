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
  fenBinaryRun = "${fenBinary}/bin/fen";
  # Only cross targets expose fenQemuSmoke; native targets have qemu = null and
  # should use fenSmoke / fenOverlaySmoke directly.
  fenQemuRun = assert qemu != null; "${pkgs.pkgsStatic.qemu-user}/bin/${qemu} ${fenBinary}/bin/fen";
  # Loads the bundled LuaSocket pieces (core + first-party-presenter submodules)
  # through a given fen runner, asserting they resolve in the embedded archive.
  luasocketSmoke = run: ''
    env -u LUA_PATH -u LUA_CPATH -u FEN_ROCKS_TREE \
      ${run} eval \
        'local socket = require("socket"); assert(socket.bind); assert(require("mime")); assert(require("socket.http")); assert(require("socket.unix")); assert(require("socket.serial")); print("LUASOCKET-OK")' \
        >> "$out"
    grep -q LUASOCKET-OK "$out"
  '';
in
{
  fenSmoke = targetPkgs.runCommand "fen-${version}-${artifactSystem}-fen-smoke"
    { nativeBuildInputs = [ buildPkgs.coreutils ]; }
    ''
      ${fenBinaryRun} --help > "$out"
      ${luasocketSmoke fenBinaryRun}

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
      FEN_BIN=$PWD/fen-binary-run sh scripts/smoke/mock.sh > "$out"
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
      FEN_BIN=$PWD/fen-binary-run checkout/scripts/dev/fen-dev --help >> "$out"
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

  fenNoDynamicDeps = targetPkgs.runCommand "fen-${version}-${artifactSystem}-fen-no-dynamic-deps"
    { nativeBuildInputs = [ pkgs.binutils pkgs.coreutils pkgs.gnugrep ]; }
    ''
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
    '';

  fennelCheck = targetPkgs.runCommand "fen-${version}-${artifactSystem}-fennel-check"
    { nativeBuildInputs = [ buildLuaPkgs.fennel buildPkgs.findutils ]; }
    ''
      cd ${../.}
      ${buildLuaPkgs.fennel}/bin/fennel scripts/test/fennel-check.fnl
      touch "$out"
    '';

  docs = targetPkgs.runCommand "fen-${version}-${artifactSystem}-docs"
    { nativeBuildInputs = [ buildLuaPkgs.fennel buildPkgs.findutils buildPkgs.graphviz ]; }
    ''
      cp -R ${../.} source
      chmod -R u+w source
      cd source
      ${buildLuaPkgs.fennel}/bin/fennel scripts/docs/gen-docs.fnl
      ${buildLuaPkgs.fennel}/bin/fennel scripts/docs/gen-graphs.fnl --kind all
      ${buildLuaPkgs.fennel}/bin/fennel scripts/docs/gen-static-docs.fnl
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

  # The unit suite runs host-side under a stock Lua interpreter and `require`s
  # native helpers (fen_http/process/random, termbox2) that run-tests.sh builds
  # as `-shared` .so modules to dlopen. That needs a dynamic toolchain + lua, so
  # this check deliberately uses the native dynamic `pkgs` rather than the
  # static `buildPkgs`/`targetPkgs` set (which cannot produce shared objects).
  tests = pkgs.runCommand "fen-${version}-${artifactSystem}-tests"
    {
      nativeBuildInputs = [
        pkgs.coreutils
        pkgs.stdenv.cc
        pkgs.curl
        pkgs.lua54Packages.fennel
        pkgs.lua54Packages.busted
        pkgs.lua54Packages.lua-cjson
        pkgs.lua54Packages.luasocket
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
      export LUA_INCDIR=${pkgs.lua5_4}/include
      export CURL_INCDIR=${pkgs.curl.dev}/include
      export CURL_LIBDIR=${pkgs.curl.out}/lib
      sh scripts/test/run-tests.sh
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
      ${luasocketSmoke fenQemuRun}

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
