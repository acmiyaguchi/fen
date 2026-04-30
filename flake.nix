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
        fenPackage = self.packages.${system}.default;
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
            FEN_PKG = fenPackage;
            FEN_LUA = lua;
            FEN_LUA_ENV = luaEnv;
            FEN_VERSION = version;
            FEN_ARTIFACT_SYSTEM = artifactSystem;
          }
          ''
            sh ${./scripts/nix-bundle-linux.sh} "$out"
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
