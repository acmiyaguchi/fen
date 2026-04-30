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
find src -type f -name '*.fnl' | sort | while IFS= read -r src; do
  out=".luarocks-build/${src#src/}"
  out="${out%.fnl}.lua"
  mkdir -p "$(dirname "$out")"
  fennel --compile "$src" > "$out"
done
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
