package = "fen-provider-openai"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
   dir = "fen/packages/providers/openai",
}

description = {
   summary = "fen LLM provider package",
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
mkdir -p .luarocks-build/fen/providers
fennel --compile src/fen/providers/openai_completions.fnl > .luarocks-build/fen/providers/openai_completions.lua
   ]],
   install = {
      lua = {
         ["fen.providers.openai_completions"] = ".luarocks-build/fen/providers/openai_completions.lua",
      },
   },
}
