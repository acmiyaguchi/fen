{ targetPkgs, lua, devLuaPackages, testRocks }:

targetPkgs.mkShell {
  packages = [
    lua
    targetPkgs.curl
    targetPkgs.curl.dev
    targetPkgs.libxcrypt
    targetPkgs.lua54Packages.fennel
    targetPkgs.stylua
    targetPkgs.graphviz
    targetPkgs.xdot
    targetPkgs.gnumake
    targetPkgs.gcc
    # Hero demo tooling (issue #141): termtosvg records a real session to
    # asciicast-v2 and renders it to an animated SVG; asciinema-agg (agg) renders
    # it to a GIF for the README, quantized by gifsicle. Used only by the opt-in
    # scripts/docs/record-hero-cast.sh helper.
    targetPkgs.termtosvg
    targetPkgs.asciinema-agg
    targetPkgs.gifsicle
  ] ++ devLuaPackages ++ testRocks;
  shellHook = ''
    # Lua headers for compiling vendored native modules.
    export LUA_INCDIR=${lua}/include
    export CURL_INCDIR=${targetPkgs.curl.dev}/include
    export CURL_LIBDIR=${targetPkgs.curl.out}/lib
    export CPATH=${targetPkgs.libxcrypt}/include:$CPATH
    export LIBRARY_PATH=${targetPkgs.libxcrypt}/lib:$LIBRARY_PATH
    export LD_LIBRARY_PATH=${targetPkgs.libxcrypt}/lib:$LD_LIBRARY_PATH
    export PATH="$PWD/bin:$PATH"
  '';
}
