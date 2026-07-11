package = "fen-ext-profiler"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
   dir = "fen/extensions/behaviors/inspectors/profiler",
}

description = {
   summary = "fen opt-in statistical profiler extension",
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
[ -f .lrbuild/.fen-precompiled ] || "${FENNEL:-fennel}" "${FEN_WORKSPACE:?set FEN_WORKSPACE to build this rock without fen}/scripts/build/fennel-build.fnl" --lrbuild
   ]],
   install = {
      lua = {
         ["fen.extensions.profiler"] = ".lrbuild/extensions/profiler/init.lua",
         ["fen.extensions.profiler.manifest"] = ".lrbuild/extensions/profiler/manifest.lua",
         ["fen.extensions.profiler.state"] = ".lrbuild/extensions/profiler/state.lua",
         ["fen.extensions.profiler.commands"] = ".lrbuild/extensions/profiler/commands.lua",
         ["fen.extensions.profiler.export"] = ".lrbuild/extensions/profiler/export.lua",
      },
   },
}
