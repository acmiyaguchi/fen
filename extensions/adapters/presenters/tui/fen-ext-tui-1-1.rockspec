package = "fen-ext-tui"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
   dir = "fen/extensions/adapters/presenters/tui",
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

external_dependencies = {
   LUA = { header = "lua.h" },
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
         ["fen.extensions.tui.clipboard"] = ".lrbuild/extensions/tui/clipboard.lua",
         ["fen.extensions.tui.completion"] = ".lrbuild/extensions/tui/completion.lua",
         ["fen.extensions.tui.draw"] = ".lrbuild/extensions/tui/draw.lua",
         ["fen.extensions.tui.ingest"] = ".lrbuild/extensions/tui/ingest.lua",
         ["fen.extensions.tui"] = ".lrbuild/extensions/tui/init.lua",
         ["fen.extensions.tui.input"] = ".lrbuild/extensions/tui/input.lua",
         ["fen.extensions.tui.manifest"] = ".lrbuild/extensions/tui/manifest.lua",
         ["fen.extensions.tui.markdown"] = ".lrbuild/extensions/tui/markdown.lua",
         ["fen.extensions.tui.paint"] = ".lrbuild/extensions/tui/paint.lua",
         ["fen.extensions.tui.panels.busy"] = ".lrbuild/extensions/tui/panels/busy.lua",
         ["fen.extensions.tui.panels.errors"] = ".lrbuild/extensions/tui/panels/errors.lua",
         ["fen.extensions.tui.panels.status"] = ".lrbuild/extensions/tui/panels/status.lua",
         ["fen.extensions.tui.panels.transcript"] = ".lrbuild/extensions/tui/panels/transcript.lua",
         ["fen.extensions.tui.redraw"] = ".lrbuild/extensions/tui/redraw.lua",
         ["fen.extensions.tui.select"] = ".lrbuild/extensions/tui/select.lua",
         ["fen.extensions.tui.selection"] = ".lrbuild/extensions/tui/selection.lua",
         ["fen.extensions.tui.state"] = ".lrbuild/extensions/tui/state.lua",
      },
      lib = {
         ["termbox2"] = ".lrbuild/termbox2.so",
      },
   },
}
