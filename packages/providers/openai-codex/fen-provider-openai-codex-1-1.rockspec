package = "fen-provider-openai-codex"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
   dir = "fen/packages/providers/openai-codex",
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
fennel --compile src/fen/providers/openai_codex_keychain.fnl > .luarocks-build/fen/providers/openai_codex_keychain.lua
mkdir -p .luarocks-build/fen/providers
fennel --compile src/fen/providers/openai_codex_oauth.fnl > .luarocks-build/fen/providers/openai_codex_oauth.lua
mkdir -p .luarocks-build/fen/providers
fennel --compile src/fen/providers/openai_codex_responses.fnl > .luarocks-build/fen/providers/openai_codex_responses.lua
mkdir -p .luarocks-build/fen/providers
fennel --compile src/fen/providers/openai_responses.fnl > .luarocks-build/fen/providers/openai_responses.lua
mkdir -p .luarocks-build/fen/providers
fennel --compile src/fen/providers/openai_responses_shared.fnl > .luarocks-build/fen/providers/openai_responses_shared.lua
   ]],
   install = {
      lua = {
         ["fen.providers.openai_codex_keychain"] = ".luarocks-build/fen/providers/openai_codex_keychain.lua",
         ["fen.providers.openai_codex_oauth"] = ".luarocks-build/fen/providers/openai_codex_oauth.lua",
         ["fen.providers.openai_codex_responses"] = ".luarocks-build/fen/providers/openai_codex_responses.lua",
         ["fen.providers.openai_responses"] = ".luarocks-build/fen/providers/openai_responses.lua",
         ["fen.providers.openai_responses_shared"] = ".luarocks-build/fen/providers/openai_responses_shared.lua",
      },
   },
}
