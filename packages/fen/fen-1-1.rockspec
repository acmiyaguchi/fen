package = "fen"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
   dir = "fen/packages/fen",
}

description = {
   summary = "Kitchen-sink fen CLI rock",
   license = "MIT",
}

dependencies = {
   "lua >= 5.4",
   "fen-core >= 1-1",
   "fen-util >= 1-1",
   "fen-provider-openai >= 1-1",
   "fen-provider-openai-codex >= 1-1",
   "fen-provider-anthropic >= 1-1",
   "fen-ext-builtin-tools >= 1-1",
   "fen-ext-builtin-commands >= 1-1",
   "fen-ext-default-prompt >= 1-1",
   "fen-ext-tui >= 1-1",
   "fen-ext-mem >= 1-1",
   "fen-ext-skills >= 1-1",
   "fen-ext-agent-state >= 1-1",
   "fen-ext-handoff >= 1-1",
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
mkdir -p .luarocks-build/fen
fennel --compile src/fen/main.fnl > .luarocks-build/fen/main.lua
mkdir -p .luarocks-build/fen
printf 'return "%s"\n' "${FEN_VERSION:-unknown}" > .luarocks-build/fen/version.lua
   ]],
   install = {
      lua = {
         ["fen.main"] = ".luarocks-build/fen/main.lua",
         ["fen.version"] = ".luarocks-build/fen/version.lua",
      },
      bin = {
         ["fen"] = "../../bin/fen.lua",
      },
   },
}
