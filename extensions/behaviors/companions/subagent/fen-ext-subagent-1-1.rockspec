package = "fen-ext-subagent"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
   dir = "fen/extensions/behaviors/companions/subagent",
}

description = {
   summary = "fen first-party extension package",
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
# fen ext build compiles in process and drops this marker so we skip the
# bootstrap compile. A standalone `luarocks make` (no fen) sets FEN_WORKSPACE to
# reach the shared build driver; see docs/extensions.md.
[ -f .lrbuild/.fen-precompiled ] || "${FENNEL:-fennel}" "${FEN_WORKSPACE:?set FEN_WORKSPACE to build this rock without fen}/scripts/build/fennel-build.fnl" --lrbuild
   ]],
   install = {
      lua = {
         ["fen.extensions.subagent"] = ".lrbuild/extensions/subagent/init.lua",
         ["fen.extensions.subagent.bundled"] = ".lrbuild/extensions/subagent/bundled.lua",
         ["fen.extensions.subagent.channel"] = ".lrbuild/extensions/subagent/channel.lua",
         ["fen.extensions.subagent.discover"] = ".lrbuild/extensions/subagent/discover.lua",
         ["fen.extensions.subagent.manifest"] = ".lrbuild/extensions/subagent/manifest.lua",
         ["fen.extensions.subagent.runs"] = ".lrbuild/extensions/subagent/runs.lua",
         ["fen.extensions.subagent.state"] = ".lrbuild/extensions/subagent/state.lua",
         ["fen.extensions.subagent.worktrees"] = ".lrbuild/extensions/subagent/worktrees.lua",
      },
   },
}
