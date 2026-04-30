package = "fen-util"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
   dir = "fen/packages/util",
}

description = {
   summary = "fen utility modules",
   license = "MIT",
}

dependencies = {
   "lua >= 5.4",
   "lua-cjson >= 2.1",
   "lua-curl >= 0.3",
   "fennel >= 1.4",
}

test_dependencies = {
   "busted >= 2.0",
}

build = {
   type = "command",
   build_command = [[
set -eu
rm -rf .luarocks-build
PATH="$(SCRIPTS_DIR):$PATH"
mkdir -p .luarocks-build/fen/util
fennel --compile src/fen/util/base64.fnl > .luarocks-build/fen/util/base64.lua
mkdir -p .luarocks-build/fen/util
fennel --compile src/fen/util/checksum.fnl > .luarocks-build/fen/util/checksum.lua
mkdir -p .luarocks-build/fen/util
fennel --compile src/fen/util/http.fnl > .luarocks-build/fen/util/http.lua
mkdir -p .luarocks-build/fen/util
fennel --compile src/fen/util/json.fnl > .luarocks-build/fen/util/json.lua
mkdir -p .luarocks-build/fen/util
fennel --compile src/fen/util/log.fnl > .luarocks-build/fen/util/log.lua
mkdir -p .luarocks-build/fen/util
fennel --compile src/fen/util/path.fnl > .luarocks-build/fen/util/path.lua
mkdir -p .luarocks-build/fen/util
fennel --compile src/fen/util/process.fnl > .luarocks-build/fen/util/process.lua
mkdir -p .luarocks-build/fen/util
fennel --compile src/fen/util/sse.fnl > .luarocks-build/fen/util/sse.lua
   ]],
   install = {
      lua = {
         ["fen.util.base64"] = ".luarocks-build/fen/util/base64.lua",
         ["fen.util.checksum"] = ".luarocks-build/fen/util/checksum.lua",
         ["fen.util.http"] = ".luarocks-build/fen/util/http.lua",
         ["fen.util.json"] = ".luarocks-build/fen/util/json.lua",
         ["fen.util.log"] = ".luarocks-build/fen/util/log.lua",
         ["fen.util.path"] = ".luarocks-build/fen/util/path.lua",
         ["fen.util.process"] = ".luarocks-build/fen/util/process.lua",
         ["fen.util.sse"] = ".luarocks-build/fen/util/sse.lua",
      },
   },
}
