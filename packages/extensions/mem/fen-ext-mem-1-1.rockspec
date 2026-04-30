package = "fen-ext-mem"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
   dir = "fen/packages/extensions/mem",
}

description = {
   summary = "fen first-party extension package",
   license = "MIT",
}

dependencies = {
   "lua >= 5.4",
   "fen-core >= 1-1",
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
   ]],
   install = {
      lua = {
         ["fen.extensions.mem"] = ".luarocks-build/fen/extensions/mem/init.lua",
         ["fen.extensions.mem.manifest"] = ".luarocks-build/fen/extensions/mem/manifest.lua",
         ["fen.extensions.mem.state"] = ".luarocks-build/fen/extensions/mem/state.lua",
      },
   },
}
