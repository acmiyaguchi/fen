package = "fen-ext-tui"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
   dir = "fen/packages/extensions/tui",
}

description = {
   summary = "fen first-party extension package",
   license = "MIT",
}

dependencies = {
   "lua >= 5.4",
   "fen-core >= 1-1",
   "luaposix >= 36",
   "fen-util >= 1-1",
}

external_dependencies = {
   LUA = { header = "lua.h" },
}

test_dependencies = {
   "busted >= 2.0",
}

build = {
   type = "builtin",
   modules = {
      ["fen.extensions.tui.draw"] = "dist/fen/extensions/tui/draw.lua",
      ["fen.extensions.tui.ingest"] = "dist/fen/extensions/tui/ingest.lua",
      ["fen.extensions.tui"] = "dist/fen/extensions/tui/init.lua",
      ["fen.extensions.tui.input"] = "dist/fen/extensions/tui/input.lua",
      ["fen.extensions.tui.manifest"] = "dist/fen/extensions/tui/manifest.lua",
      ["fen.extensions.tui.markdown"] = "dist/fen/extensions/tui/markdown.lua",
      ["fen.extensions.tui.paint"] = "dist/fen/extensions/tui/paint.lua",
      ["fen.extensions.tui.panels.busy"] = "dist/fen/extensions/tui/panels/busy.lua",
      ["fen.extensions.tui.panels.status"] = "dist/fen/extensions/tui/panels/status.lua",
      ["fen.extensions.tui.panels.transcript"] = "dist/fen/extensions/tui/panels/transcript.lua",
      ["fen.extensions.tui.select"] = "dist/fen/extensions/tui/select.lua",
      ["fen.extensions.tui.state"] = "dist/fen/extensions/tui/state.lua",
      termbox2 = {
         sources = { "vendor/lua_termbox2.c" },
         incdirs = { "vendor" },
      },
   },
}
