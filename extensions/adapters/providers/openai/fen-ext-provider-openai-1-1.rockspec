package = "fen-ext-provider-openai"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
   dir = "fen/extensions/adapters/providers/openai",
}

description = {
   summary = "fen first-party OpenAI provider extension",
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
if [ -n "${FEN_WORKSPACE:-}" ] && [ -f "$FEN_WORKSPACE/scripts/build/fennel-build.fnl" ]; then
  "${FENNEL:-fennel}" "$FEN_WORKSPACE/scripts/build/fennel-build.fnl" --lrbuild
else
  rm -rf .lrbuild
  SNAKE=provider_openai
  find . -type f -name '*.fnl' \
    -not -path './tests/*' \
    -not -path './vendor/*' \
    -not -path './.lrbuild/*' \
    -not -path './dist/*' \
    | sort | while IFS= read -r src; do
    rel="${src#./}"
    out=".lrbuild/extensions/${SNAKE}/${rel%.fnl}.lua"
    mkdir -p "$(dirname "$out")"
    "${FENNEL:-fennel}" --compile "$src" > "$out"
  done
fi
   ]],
   install = {
      lua = {
         ["fen.extensions.provider_openai"] = ".lrbuild/extensions/provider_openai/init.lua",
         ["fen.extensions.provider_openai.manifest"] = ".lrbuild/extensions/provider_openai/manifest.lua",
         ["fen.extensions.provider_openai.openai_completions"] = ".lrbuild/extensions/provider_openai/openai_completions.lua",
         ["fen.extensions.provider_openai.openai_responses"] = ".lrbuild/extensions/provider_openai/openai_responses.lua",
         ["fen.extensions.provider_openai.openai_responses_shared"] = ".lrbuild/extensions/provider_openai/openai_responses_shared.lua",
         ["fen.extensions.provider_openai.openai_codex_keychain"] = ".lrbuild/extensions/provider_openai/openai_codex_keychain.lua",
         ["fen.extensions.provider_openai.openai_codex_login"] = ".lrbuild/extensions/provider_openai/openai_codex_login.lua",
         ["fen.extensions.provider_openai.openai_codex_oauth"] = ".lrbuild/extensions/provider_openai/openai_codex_oauth.lua",
         ["fen.extensions.provider_openai.openai_codex_responses"] = ".lrbuild/extensions/provider_openai/openai_codex_responses.lua",
      },
   },
}
