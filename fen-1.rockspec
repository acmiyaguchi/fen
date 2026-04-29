package = "fen"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
}

description = {
   summary = "Minimal Lua/Fennel coding agent for ARMv7 and friends",
   detailed = [[
      A small AI coding-agent CLI, written in Fennel and compiled to Lua.
      Mirrors pi-mono's module shape (LLM client / agent loop / TUI) in
      vastly simplified form. Targets OpenAI's Chat Completions API.
   ]],
   license = "MIT",
}

dependencies = {
   "lua >= 5.1",
   "lua-curl >= 0.3",
   "lua-cjson >= 2.1",
   "fennel >= 1.4",
}

test_dependencies = {
   "busted >= 2.0",
}

test = {
   type = "command",
   command = "make test",
}

build = {
   type = "builtin",
   modules = {
      ["fen.main"]                              = "dist/main.lua",
      ["fen.core.types"]                        = "dist/core/types.lua",
      ["fen.core.llm"]                          = "dist/core/llm.lua",
      ["fen.core.agent"]                        = "dist/core/agent.lua",
      ["fen.core.tools"]                        = "dist/core/tools.lua",
      ["fen.providers.openai_completions"]      = "dist/providers/openai_completions.lua",
      ["fen.providers.openai_responses"]        = "dist/providers/openai_responses.lua",
      ["fen.providers.openai_responses_shared"] = "dist/providers/openai_responses_shared.lua",
      ["fen.providers.openai_codex_responses"]  = "dist/providers/openai_codex_responses.lua",
      ["fen.providers.anthropic_messages"]      = "dist/providers/anthropic_messages.lua",
      ["fen.auth.storage"]                      = "dist/auth/storage.lua",
      ["fen.auth.openai_codex"]                 = "dist/auth/openai_codex.lua",
      ["fen.util.base64"]                       = "dist/util/base64.lua",
      ["fen.tui.tui"]                           = "dist/tui/tui.lua",
      ["fen.tui.state"]                         = "dist/tui/state.lua",
      ["fen.util.json"]                         = "dist/util/json.lua",
      ["fen.util.log"]                          = "dist/util/log.lua",
      -- Vendored Lua C binding for termbox2; no published lua-termbox2 rock
      -- exists, so the C shim ships in-tree under vendor/.
      termbox2 = {
         sources = { "vendor/lua_termbox2.c" },
         incdirs = { "vendor" },
      },
   },
   install = {
      bin = { ["fen"] = "bin/fen" },
   },
}
