package = "fen-ext-skills"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
   dir = "fen/extensions/behaviors/companions/skills",
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
         ["fen.extensions.skills.bundled"] = ".lrbuild/extensions/skills/bundled.lua",
         ["fen.extensions.skills.bundled_data"] = ".lrbuild/extensions/skills/bundled_data.lua",
         ["fen.extensions.skills.ignore"] = ".lrbuild/extensions/skills/ignore.lua",
         ["fen.extensions.skills.state"] = ".lrbuild/extensions/skills/state.lua",
         ["fen.extensions.skills"] = ".lrbuild/extensions/skills/init.lua",
         ["fen.extensions.skills.manifest"] = ".lrbuild/extensions/skills/manifest.lua",
      },
   },
}
