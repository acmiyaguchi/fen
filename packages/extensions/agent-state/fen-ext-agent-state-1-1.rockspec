package = "fen-ext-agent-state"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
   dir = "fen/packages/extensions/agent-state",
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
mkdir -p .luarocks-build/fen/extensions/agent_state
fennel --compile src/fen/extensions/agent_state/init.fnl > .luarocks-build/fen/extensions/agent_state/init.lua
mkdir -p .luarocks-build/fen/extensions/agent_state
fennel --compile src/fen/extensions/agent_state/manifest.fnl > .luarocks-build/fen/extensions/agent_state/manifest.lua
mkdir -p .luarocks-build/fen/extensions/agent_state
fennel --compile src/fen/extensions/agent_state/tool.fnl > .luarocks-build/fen/extensions/agent_state/tool.lua
   ]],
   install = {
      lua = {
         ["fen.extensions.agent_state"] = ".luarocks-build/fen/extensions/agent_state/init.lua",
         ["fen.extensions.agent_state.manifest"] = ".luarocks-build/fen/extensions/agent_state/manifest.lua",
         ["fen.extensions.agent_state.tool"] = ".luarocks-build/fen/extensions/agent_state/tool.lua",
      },
   },
}
