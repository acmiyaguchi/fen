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
   type = "builtin",
   modules = {
      ["fen.main"] = "dist/fen/main.lua",
      ["fen.version"] = "dist/fen/version.lua",
   },
   install = {
      bin = { ["fen"] = "../../bin/fen.lua" },
   },
}
