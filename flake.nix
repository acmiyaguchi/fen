{
  description = "agent-fennel: minimal Lua/Fennel coding agent";

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
        nixpkgsRocks = with luaPkgs; [ lua-curl lua-cjson fennel ];
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
          ] ++ nixpkgsRocks ++ testRocks;
          shellHook = ''
            export AGENT_FENNEL_LUA=${lua}/bin/lua
            # Make rocks installed into lua_modules/ visible.
            export LUA_PATH="$PWD/lua_modules/share/lua/5.4/?.lua;$PWD/lua_modules/share/lua/5.4/?/init.lua;$LUA_PATH"
            export LUA_CPATH="$PWD/lua_modules/lib/lua/5.4/?.so;$LUA_CPATH"
            # Project bin/ + locally installed rocks both on PATH.
            export PATH="$PWD/bin:$PWD/lua_modules/bin:$PATH"
          '';
        };
      });
}
