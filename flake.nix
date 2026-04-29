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
        # Runtime rocks available directly from nixpkgs.
        nixpkgsRocks = with luaPkgs; [ lua-curl lua-cjson fennel luaposix ];
        # Test-only rocks; not needed by the distributed tarball.
        testRocks = with luaPkgs; [ busted ];
      in {
        devShells.default = pkgs.mkShell {
          packages = [
            lua
            pkgs.luarocks
            pkgs.curl
            pkgs.stylua
            pkgs.gnumake
            pkgs.gcc
          ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
            pkgs.gdb
            pkgs.valgrind
          ] ++ nixpkgsRocks ++ testRocks;
          shellHook = ''
            export FEN_LUA=${lua}/bin/lua
            # Lua headers for compiling vendor/lua_termbox2.c via the Makefile.
            export LUA_INCDIR=${lua}/include
            # Make rocks installed into lua_modules/ visible, plus dist/ for
            # the vendored termbox2.so produced by `make build`.
            export LUA_PATH="$PWD/lua_modules/share/lua/5.4/?.lua;$PWD/lua_modules/share/lua/5.4/?/init.lua;$LUA_PATH"
            export LUA_CPATH="$PWD/dist/?.so;$PWD/lua_modules/lib/lua/5.4/?.so;$LUA_CPATH"
            # Project bin/ + locally installed rocks both on PATH.
            export PATH="$PWD/bin:$PWD/lua_modules/bin:$PATH"
            # Let `make run-debug` / manual runs write core files when the OS
            # allows it. On NixOS/systemd, inspect them with `coredumpctl`.
            ulimit -c unlimited 2>/dev/null || true
          '';
        };
      });
}
