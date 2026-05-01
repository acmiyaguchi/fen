{ targetPkgs, lua, luarocks54, nixpkgsRocks, testRocks }:

targetPkgs.mkShell {
  packages = [
    lua
    luarocks54
    targetPkgs.curl
    targetPkgs.curl.dev
    targetPkgs.libxcrypt
    targetPkgs.lua54Packages.fennel
    targetPkgs.stylua
    targetPkgs.gnumake
    targetPkgs.gcc
  ] ++ nixpkgsRocks ++ testRocks;
  shellHook = ''
    export FEN_LUA=${lua}/bin/lua
    export LUAROCKS=${luarocks54}/bin/luarocks
    # Lua headers for compiling vendored native modules.
    export LUA_INCDIR=${lua}/include
    export CURL_INCDIR=${targetPkgs.curl.dev}/include
    export CURL_LIBDIR=${targetPkgs.curl.out}/lib
    export CPATH=${targetPkgs.libxcrypt}/include:$CPATH
    export LIBRARY_PATH=${targetPkgs.libxcrypt}/lib:$LIBRARY_PATH
    export LD_LIBRARY_PATH=${targetPkgs.libxcrypt}/lib:$LD_LIBRARY_PATH
    # Make rocks installed into lua_modules/ visible, plus local native modules
    # produced by scripts/build-native-modules.sh when needed.
    export LUA_PATH="$PWD/lua_modules/share/lua/5.4/?.lua;$PWD/lua_modules/share/lua/5.4/?/init.lua;$LUA_PATH"
    export LUA_CPATH="$PWD/packages/extensions/tui/dist/?.so;$PWD/lua_modules/lib/lua/5.4/?.so;$LUA_CPATH"
    # Project bin/ + locally installed rocks both on PATH.
    export PATH="$PWD/bin:$PWD/lua_modules/bin:$PATH"
  '';
}
