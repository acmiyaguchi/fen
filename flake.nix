{
  description = "fen: minimal Lua/Fennel coding agent";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        lua = pkgs.lua5_4;
        luaPkgs = pkgs.lua54Packages;
        luarocks54 = luaPkgs.luarocks or (pkgs.luarocks.override { lua = lua; });
        # Runtime rocks available directly from nixpkgs.
        nixpkgsRocks = with luaPkgs; [ lua-curl lua-cjson fennel luaposix luasocket ];
        # Test-only rocks; not needed by the distributed tarball.
        testRocks = with luaPkgs; [ busted ];
        luaEnv = lua.withPackages (_: nixpkgsRocks);
        version = self.shortRev or self.dirtyShortRev or "unknown";
        artifactSystem =
          if system == "x86_64-linux" then "linux-x86_64"
          else if system == "aarch64-linux" then "linux-aarch64"
          else if system == "armv7l-linux" then "linux-armv7-gnueabihf"
          else system;
      in {
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "fen";
          inherit version;
          src = ./.;

          nativeBuildInputs = [
            pkgs.gnumake
            pkgs.makeWrapper
            pkgs.pkg-config
            luaPkgs.fennel
          ];

          buildInputs = [
            lua
            pkgs.curl
            pkgs.libxcrypt
          ];

          buildPhase = ''
            runHook preBuild
            make build \
              FENNEL=${luaPkgs.fennel}/bin/fennel \
              LUA_INCDIR=${lua}/include \
              VERSION=${version}
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            mkdir -p "$out/share/lua/5.4" "$out/lib/lua/5.4" "$out/share/fen/bin" "$out/bin"

            # Merge every package's compiled Lua modules into one Lua search root.
            for d in packages/*/dist packages/*/*/dist; do
              if [ -d "$d" ]; then
                cp -R "$d"/. "$out/share/lua/5.4/"
              fi
            done

            # The termbox2 binding is a C module required as `termbox2`.
            if [ -f packages/extensions/tui/dist/termbox2.so ]; then
              install -Dm755 packages/extensions/tui/dist/termbox2.so \
                "$out/lib/lua/5.4/termbox2.so"
              rm -f "$out/share/lua/5.4/termbox2.so"
            fi

            install -Dm755 bin/fen.lua "$out/share/fen/bin/fen.lua"

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
        packages.fen = self.packages.${system}.default;

        apps.default = flake-utils.lib.mkApp { drv = self.packages.${system}.default; };

        packages.dist = pkgs.runCommand "fen-${version}-${artifactSystem}-dist"
          {
            nativeBuildInputs = [ pkgs.coreutils pkgs.findutils pkgs.gawk pkgs.gnutar pkgs.gzip pkgs.glibc.bin pkgs.patchelf ];
          }
          ''
            set -eu

            name="fen-${version}-${artifactSystem}"
            root="$PWD/$name"
            pkg=${self.packages.${system}.default}

            mkdir -p \
              "$root/bin" \
              "$root/lib" \
              "$root/libexec" \
              "$root/lib/lua/5.4" \
              "$root/share/lua/5.4" \
              "$root/share/fen/bin"

            cp -RL "$pkg/share/lua/5.4"/. "$root/share/lua/5.4/"
            cp -RL "$pkg/lib/lua/5.4"/. "$root/lib/lua/5.4/"
            cp "$pkg/share/fen/bin/fen.lua" "$root/share/fen/bin/fen.lua"

            # Copy the Lua interpreter itself plus the Lua modules supplied by
            # nixpkgs rocks. The phase-1 Nix package can rely on store paths;
            # this bundle is meant to be extracted elsewhere, so it carries the
            # runtime module tree directly.
            cp ${lua}/bin/lua "$root/libexec/lua"
            if [ -d ${luaEnv}/share/lua/5.4 ]; then
              cp -RL ${luaEnv}/share/lua/5.4/. "$root/share/lua/5.4/"
            fi
            if [ -d ${luaEnv}/lib/lua/5.4 ]; then
              cp -RL ${luaEnv}/lib/lua/5.4/. "$root/lib/lua/5.4/"
            fi

            # Copy shared-library dependencies reported by ldd for the bundled
            # Lua executable and C modules. Iterate because copied libraries have
            # their own dependencies. The wrapper below invokes the bundled ELF
            # loader explicitly, avoiding an absolute /nix/store PT_INTERP path.
            copy_deps() {
              while IFS= read -r elf; do
                ldd "$elf" 2>/dev/null \
                  | awk '
                      /=> \/nix\/store\// { print $3 }
                      /^\/nix\/store\// { print $1 }
                    ' \
                  | while IFS= read -r lib; do
                      if [ -n "$lib" ] && [ -f "$lib" ] && [ ! -e "$root/lib/$(basename "$lib")" ]; then
                        cp -L "$lib" "$root/lib/$(basename "$lib")"
                        echo copied > "$root/.deps-changed"
                      fi
                    done
              done <<EOF
$(find "$root" -type f \( -perm -0100 -o -name '*.so' -o -name '*.so.*' \))
EOF
              if [ -e "$root/.deps-changed" ]; then
                rm "$root/.deps-changed"
                return 0
              fi
              return 1
            }

            while copy_deps; do :; done

            interp=$(ldd "$root/libexec/lua" | awk '/ld-linux|ld-musl/ { print $1; exit }')
            interp_base=$(basename "$interp")

            chmod -R u+rwX "$root"

            # Drop Nix store RUNPATHs from copied ELF files. The launcher uses
            # the bundled loader with --library-path, and these relative RPATHs
            # keep direct execution/debugging pointed at the bundle too.
            patchelf --set-rpath '$ORIGIN/../lib' "$root/libexec/lua"
            while IFS= read -r so; do
              patchelf --set-rpath '$ORIGIN/../../../lib' "$so" 2>/dev/null || true
            done <<EOF
$(find "$root/lib/lua/5.4" -type f \( -name '*.so' -o -name '*.so.*' \))
EOF

            cat > "$root/bin/fen" <<EOF
#!/bin/sh
set -eu
BIN_DIR=\$(CDPATH= cd -- "\$(dirname -- "\$0")" && pwd)
ROOT=\$(dirname "\$BIN_DIR")
export LUA_PATH="\$ROOT/share/lua/5.4/?.lua;\$ROOT/share/lua/5.4/?/init.lua;\''${LUA_PATH:-;;}"
export LUA_CPATH="\$ROOT/lib/lua/5.4/?.so;\''${LUA_CPATH:-;;}"
LIB_PATH="\$ROOT/lib\''${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "\$ROOT/lib/$interp_base" --library-path "\$LIB_PATH" "\$ROOT/libexec/lua" "\$ROOT/share/fen/bin/fen.lua" "\$@"
EOF
            chmod -R u+rwX "$root"
            chmod +x "$root/bin/fen" "$root/libexec/lua"

            cat > "$root/README.txt" <<EOF
fen ${version} portable Linux bundle (${artifactSystem})

Run with:

  ./bin/fen --help

This bundle carries Lua 5.4, fen's compiled Lua modules, Lua C modules,
and the shared libraries reported by ldd at build time. It is intended for
Linux distributions on the same architecture/ABI as the artifact name.
EOF

            mkdir -p "$out"
            tar czf "$out/$name.tar.gz" -C "$PWD" "$name"
          '';

        devShells.default = pkgs.mkShell {
          packages = [
            lua
            luarocks54
            pkgs.curl
            pkgs.curl.dev
            pkgs.libxcrypt
            pkgs.stylua
            pkgs.gnumake
            pkgs.gcc
          ] ++ nixpkgsRocks ++ testRocks;
          shellHook = ''
            export FEN_LUA=${lua}/bin/lua
            export LUAROCKS=${luarocks54}/bin/luarocks
            # Lua headers for compiling vendor/lua_termbox2.c via the Makefile.
            export LUA_INCDIR=${lua}/include
            export CURL_INCDIR=${pkgs.curl.dev}/include
            export CURL_LIBDIR=${pkgs.curl.out}/lib
            export CPATH=${pkgs.libxcrypt}/include:$CPATH
            export LIBRARY_PATH=${pkgs.libxcrypt}/lib:$LIBRARY_PATH
            export LD_LIBRARY_PATH=${pkgs.libxcrypt}/lib:$LD_LIBRARY_PATH
            # Make rocks installed into lua_modules/ visible, plus dist/ for
            # the vendored termbox2.so produced by `make build`.
            export LUA_PATH="$PWD/lua_modules/share/lua/5.4/?.lua;$PWD/lua_modules/share/lua/5.4/?/init.lua;$LUA_PATH"
            export LUA_CPATH="$PWD/packages/extensions/tui/dist/?.so;$PWD/lua_modules/lib/lua/5.4/?.so;$LUA_CPATH"
            # Project bin/ + locally installed rocks both on PATH.
            export PATH="$PWD/bin:$PWD/lua_modules/bin:$PATH"
          '';
        };
      });
}
