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
   "fen-ext-provider-shared >= 1-1",
}

test_dependencies = {
   "busted >= 2.0",
}

build = {
   type = "command",
   build_command = [[
set -eu
# fen ext build compiles in process and drops this marker so we skip the
# bootstrap compile. A standalone `luarocks make` (no fen) sets FEN_WORKSPACE to
# reach the shared build driver; see docs/extensions.md.
[ -f .lrbuild/.fen-precompiled ] || "${FENNEL:-fennel}" "${FEN_WORKSPACE:?set FEN_WORKSPACE to build this rock without fen}/scripts/build/fennel-build.fnl" --lrbuild
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
