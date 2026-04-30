package = "fen-ext-handoff"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
   dir = "fen/packages/extensions/handoff",
}

description = {
   summary = "fen first-party extension package",
   license = "MIT",
}

dependencies = {
   "lua >= 5.4",
   "fen-core >= 1-1",
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
mkdir -p .luarocks-build/fen/extensions/handoff
fennel --compile src/fen/extensions/handoff/init.fnl > .luarocks-build/fen/extensions/handoff/init.lua
mkdir -p .luarocks-build/fen/extensions/handoff
fennel --compile src/fen/extensions/handoff/manifest.fnl > .luarocks-build/fen/extensions/handoff/manifest.lua
   ]],
   install = {
      lua = {
         ["fen.extensions.handoff"] = ".luarocks-build/fen/extensions/handoff/init.lua",
         ["fen.extensions.handoff.manifest"] = ".luarocks-build/fen/extensions/handoff/manifest.lua",
      },
   },
}
