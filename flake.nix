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
        nixpkgsRocks = with luaPkgs; [ lua-curl lua-cjson fennel luaposix ];
        # Test-only rocks; not needed by the distributed tarball.
        testRocks = with luaPkgs; [ busted ];
      in {
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
