package = "agent-fennel"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://example.invalid/agent-fennel.git",
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
      ["agent-fennel.main"]                              = "dist/main.lua",
      ["agent-fennel.core.types"]                        = "dist/core/types.lua",
      ["agent-fennel.core.llm"]                          = "dist/core/llm.lua",
      ["agent-fennel.core.agent"]                        = "dist/core/agent.lua",
      ["agent-fennel.core.tools"]                        = "dist/core/tools.lua",
      ["agent-fennel.providers.openai_completions"]      = "dist/providers/openai_completions.lua",
      ["agent-fennel.providers.anthropic_messages"]      = "dist/providers/anthropic_messages.lua",
      ["agent-fennel.tui.tui"]                           = "dist/tui/tui.lua",
      ["agent-fennel.tui.state"]                         = "dist/tui/state.lua",
      ["agent-fennel.util.json"]                         = "dist/util/json.lua",
      ["agent-fennel.util.log"]                          = "dist/util/log.lua",
      -- Vendored Lua C binding for termbox2; no published lua-termbox2 rock
      -- exists, so the C shim ships in-tree under vendor/.
      termbox2 = {
         sources = { "vendor/lua_termbox2.c" },
         incdirs = { "vendor" },
      },
   },
   install = {
      bin = { ["agent-fennel"] = "bin/agent-fennel" },
   },
}
