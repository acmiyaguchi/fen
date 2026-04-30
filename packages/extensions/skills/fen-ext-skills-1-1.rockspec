package = "fen-ext-skills"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
   dir = "fen/packages/extensions/skills",
}

description = {
   summary = "fen first-party extension package",
   license = "MIT",
}

dependencies = {
   "lua >= 5.4",
   "fen-core >= 1-1",
   "fen-util >= 1-1",
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
mkdir -p .luarocks-build/fen/extensions/skills
fennel --compile src/fen/extensions/skills/ignore.fnl > .luarocks-build/fen/extensions/skills/ignore.lua
mkdir -p .luarocks-build/fen/extensions/skills
fennel --compile src/fen/extensions/skills/init.fnl > .luarocks-build/fen/extensions/skills/init.lua
mkdir -p .luarocks-build/fen/extensions/skills
fennel --compile src/fen/extensions/skills/manifest.fnl > .luarocks-build/fen/extensions/skills/manifest.lua
   ]],
   install = {
      lua = {
         ["fen.extensions.skills.ignore"] = ".luarocks-build/fen/extensions/skills/ignore.lua",
         ["fen.extensions.skills"] = ".luarocks-build/fen/extensions/skills/init.lua",
         ["fen.extensions.skills.manifest"] = ".luarocks-build/fen/extensions/skills/manifest.lua",
      },
   },
}
