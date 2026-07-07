package = "fen-ext-web"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
   dir = "fen/extensions/adapters/presenters/web",
}

description = {
   summary = "fen first-party web presenter extension package",
   license = "MIT",
}

dependencies = {
   "lua >= 5.4",
   "fen-core >= 1-1",
   "fen-util >= 1-1",
   "luasocket >= 3.0",
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
         ["fen.extensions.web"] = ".lrbuild/extensions/web/init.lua",
         ["fen.extensions.web.ingest"] = ".lrbuild/extensions/web/ingest.lua",
         ["fen.extensions.web.layout"] = ".lrbuild/extensions/web/layout.lua",
         ["fen.extensions.web.manifest"] = ".lrbuild/extensions/web/manifest.lua",
         ["fen.extensions.web.page"] = ".lrbuild/extensions/web/page.lua",
         ["fen.extensions.web.server"] = ".lrbuild/extensions/web/server.lua",
         ["fen.extensions.web.state"] = ".lrbuild/extensions/web/state.lua",
      },
   },
}
