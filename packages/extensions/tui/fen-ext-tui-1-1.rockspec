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
rm -rf .luarocks-build
PATH="$(SCRIPTS_DIR):$PATH"
find src -type f -name '*.fnl' | sort | while IFS= read -r src; do
  out=".luarocks-build/${src#src/}"
  out="${out%.fnl}.lua"
  mkdir -p "$(dirname "$out")"
  fennel --compile "$src" > "$out"
done
mkdir -p .luarocks-build
$(CC) $(CFLAGS) -I$(LUA_INCDIR) -Ivendor -shared vendor/lua_termbox2.c -o .luarocks-build/termbox2.so
   ]],
   install = {
      lua = {
         ["fen.extensions.tui.draw"] = ".luarocks-build/fen/extensions/tui/draw.lua",
         ["fen.extensions.tui.ingest"] = ".luarocks-build/fen/extensions/tui/ingest.lua",
         ["fen.extensions.tui"] = ".luarocks-build/fen/extensions/tui/init.lua",
         ["fen.extensions.tui.input"] = ".luarocks-build/fen/extensions/tui/input.lua",
         ["fen.extensions.tui.manifest"] = ".luarocks-build/fen/extensions/tui/manifest.lua",
         ["fen.extensions.tui.markdown"] = ".luarocks-build/fen/extensions/tui/markdown.lua",
         ["fen.extensions.tui.paint"] = ".luarocks-build/fen/extensions/tui/paint.lua",
         ["fen.extensions.tui.panels.busy"] = ".luarocks-build/fen/extensions/tui/panels/busy.lua",
         ["fen.extensions.tui.panels.status"] = ".luarocks-build/fen/extensions/tui/panels/status.lua",
         ["fen.extensions.tui.panels.transcript"] = ".luarocks-build/fen/extensions/tui/panels/transcript.lua",
         ["fen.extensions.tui.select"] = ".luarocks-build/fen/extensions/tui/select.lua",
         ["fen.extensions.tui.state"] = ".luarocks-build/fen/extensions/tui/state.lua",
      },
      lib = {
         ["termbox2"] = ".luarocks-build/termbox2.so",
      },
   },
}
