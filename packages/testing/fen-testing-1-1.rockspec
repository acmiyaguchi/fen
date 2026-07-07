package = "fen-testing"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
   dir = "fen/packages/testing",
}

description = {
   summary = "fen test helpers for package and extension tests",
   license = "MIT",
}

dependencies = {
   "lua >= 5.4",
   "fennel >= 1.4",
   "fen-core >= 1-1",
   "fen-util >= 1-1",
}

test_dependencies = {
   "busted >= 2.0",
   "fen-ext-builtin-tools >= 1-1",
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
         ["fen.testing"] = ".lrbuild/testing/init.lua",
         ["fen.testing.macros"] = "src/fen/testing/macros.fnl",
         ["fen.testing.tools"] = ".lrbuild/testing/tools.lua",
      },
   },
}
