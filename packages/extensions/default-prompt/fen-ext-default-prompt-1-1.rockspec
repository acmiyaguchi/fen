package = "fen-ext-default-prompt"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
   dir = "fen/packages/extensions/default-prompt",
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
mkdir -p .luarocks-build/fen/extensions/default_prompt
fennel --compile src/fen/extensions/default_prompt/init.fnl > .luarocks-build/fen/extensions/default_prompt/init.lua
mkdir -p .luarocks-build/fen/extensions/default_prompt
fennel --compile src/fen/extensions/default_prompt/manifest.fnl > .luarocks-build/fen/extensions/default_prompt/manifest.lua
   ]],
   install = {
      lua = {
         ["fen.extensions.default_prompt"] = ".luarocks-build/fen/extensions/default_prompt/init.lua",
         ["fen.extensions.default_prompt.manifest"] = ".luarocks-build/fen/extensions/default_prompt/manifest.lua",
      },
   },
}
