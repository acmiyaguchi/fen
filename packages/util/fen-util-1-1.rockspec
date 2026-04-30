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
find src -type f -name '*.fnl' | sort | while IFS= read -r src; do
  out=".luarocks-build/${src#src/}"
  out="${out%.fnl}.lua"
  mkdir -p "$(dirname "$out")"
  fennel --compile "$src" > "$out"
done
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
