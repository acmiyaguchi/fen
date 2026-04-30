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
   "fen-util >= 1-1",
   "luaposix >= 36",
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
rm -rf .lrbuild
PATH="$(SCRIPTS_DIR):$PATH"
find src -type f -name '*.fnl' | sort | while IFS= read -r src; do
  out=".lrbuild/${src#src/fen/}"
  out="${out%.fnl}.lua"
  mkdir -p "$(dirname "$out")"
  fennel --compile "$src" > "$out"
done
mkdir -p .lrbuild
$(CC) $(CFLAGS) -I$(LUA_INCDIR) -Ivendor -shared vendor/lua_termbox2.c -o .lrbuild/termbox2.so
   ]],
   install = {
      lua = {
         ["fen.extensions.tui.draw"] = ".lrbuild/extensions/tui/draw.lua",
         ["fen.extensions.tui.ingest"] = ".lrbuild/extensions/tui/ingest.lua",
         ["fen.extensions.tui"] = ".lrbuild/extensions/tui/init.lua",
         ["fen.extensions.tui.input"] = ".lrbuild/extensions/tui/input.lua",
         ["fen.extensions.tui.manifest"] = ".lrbuild/extensions/tui/manifest.lua",
         ["fen.extensions.tui.markdown"] = ".lrbuild/extensions/tui/markdown.lua",
         ["fen.extensions.tui.paint"] = ".lrbuild/extensions/tui/paint.lua",
         ["fen.extensions.tui.panels.busy"] = ".lrbuild/extensions/tui/panels/busy.lua",
         ["fen.extensions.tui.panels.status"] = ".lrbuild/extensions/tui/panels/status.lua",
         ["fen.extensions.tui.panels.transcript"] = ".lrbuild/extensions/tui/panels/transcript.lua",
         ["fen.extensions.tui.select"] = ".lrbuild/extensions/tui/select.lua",
         ["fen.extensions.tui.state"] = ".lrbuild/extensions/tui/state.lua",
      },
      lib = {
         ["termbox2"] = ".lrbuild/termbox2.so",
      },
   },
}
