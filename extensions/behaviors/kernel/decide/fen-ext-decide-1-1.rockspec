package = "fen-ext-decide"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
   dir = "fen/extensions/behaviors/kernel/decide",
}

description = {
   summary = "fen first-party extension package",
   license = "MIT",
}

dependencies = {
   "lua >= 5.4",
   "fen-core >= 1-1",
   "fen-util >= 1-1",
   "fen-ext-steering >= 1-1",
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
         ["fen.extensions.decide"] = ".lrbuild/extensions/decide/init.lua",
         ["fen.extensions.decide.compaction"] = ".lrbuild/extensions/decide/compaction.lua",
         ["fen.extensions.decide.input"] = ".lrbuild/extensions/decide/input.lua",
         ["fen.extensions.decide.jev"] = ".lrbuild/extensions/decide/jev.lua",
         ["fen.extensions.decide.manifest"] = ".lrbuild/extensions/decide/manifest.lua",
         ["fen.extensions.decide.openai"] = ".lrbuild/extensions/decide/openai.lua",
         ["fen.extensions.decide.service"] = ".lrbuild/extensions/decide/service.lua",
         ["fen.extensions.decide.state"] = ".lrbuild/extensions/decide/state.lua",
      },
   },
}
