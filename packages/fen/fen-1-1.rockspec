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
   "fen-ext-provider-openai >= 1-1",
   "fen-ext-provider-anthropic >= 1-1",
   "fen-ext-builtin-tools >= 1-1",
   "fen-ext-essentials >= 1-1",
   "fen-ext-sessions >= 1-1",
   "fen-ext-status >= 1-1",
   "fen-ext-profiler >= 1-1",
   "fen-ext-queue >= 1-1",
   "fen-ext-prompt >= 1-1",
   "fen-ext-extensions-inspector >= 1-1",
   "fen-ext-default-prompt >= 1-1",
   "fen-ext-tui >= 1-1",
   "fen-ext-web >= 1-1",
   "fen-ext-mem >= 1-1",
   "fen-ext-todo >= 1-1",
   "fen-ext-plan >= 1-1",
   "fen-ext-session-jsonl >= 1-1",
   "fen-ext-skills >= 1-1",
   "fen-ext-agent-state >= 1-1",
   "fen-ext-compact >= 1-1",
   "fen-ext-handoff >= 1-1",
}

test_dependencies = {
   "busted >= 2.0",
}

build = {
   type = "command",
   build_command = [[
set -eu
# The kitchen-sink fen rock is built by the packaging path, never `fen ext
# build`; a standalone `luarocks make` sets FEN_WORKSPACE to reach the shared
# build driver. See docs/distribution.md.
"${FENNEL:-fennel}" "${FEN_WORKSPACE:?set FEN_WORKSPACE to build this rock without fen}/scripts/build/fennel-build.fnl" --lrbuild
mkdir -p .lrbuild
printf 'return "%s"\n' "${FEN_VERSION:-unknown}" > .lrbuild/version.lua
   ]],
   install = {
      lua = {
         ["fen.cli_discovery"] = ".lrbuild/cli_discovery.lua",
         ["fen.interactive"] = ".lrbuild/interactive.lua",
         ["fen.main"] = ".lrbuild/main.lua",
         ["fen.provider_help"] = ".lrbuild/provider_help.lua",
         ["fen.run_state"] = ".lrbuild/run_state.lua",
         ["fen.runtime"] = ".lrbuild/runtime.lua",
         ["fen.script_runner"] = ".lrbuild/script_runner.lua",
         ["fen.session_lifecycle"] = ".lrbuild/session_lifecycle.lua",
         ["fen.tool_policy"] = ".lrbuild/tool_policy.lua",
         ["fen.turn_lifecycle"] = ".lrbuild/turn_lifecycle.lua",
         ["fen.turn_submit"] = ".lrbuild/turn_submit.lua",
         ["fen.update"] = ".lrbuild/update.lua",
         ["fen.version"] = ".lrbuild/version.lua",
      },
      bin = {
         ["fen"] = "bin/fen.lua",
      },
   },
}
