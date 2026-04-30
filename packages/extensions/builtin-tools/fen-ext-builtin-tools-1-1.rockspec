package = "fen-ext-builtin-tools"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
   dir = "fen/packages/extensions/builtin-tools",
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
         ["fen.extensions.builtin_tools.bash"] = ".luarocks-build/fen/extensions/builtin_tools/bash.lua",
         ["fen.extensions.builtin_tools.edit"] = ".luarocks-build/fen/extensions/builtin_tools/edit.lua",
         ["fen.extensions.builtin_tools.find"] = ".luarocks-build/fen/extensions/builtin_tools/find.lua",
         ["fen.extensions.builtin_tools.grep"] = ".luarocks-build/fen/extensions/builtin_tools/grep.lua",
         ["fen.extensions.builtin_tools"] = ".luarocks-build/fen/extensions/builtin_tools/init.lua",
         ["fen.extensions.builtin_tools.ls"] = ".luarocks-build/fen/extensions/builtin_tools/ls.lua",
         ["fen.extensions.builtin_tools.manifest"] = ".luarocks-build/fen/extensions/builtin_tools/manifest.lua",
         ["fen.extensions.builtin_tools.read"] = ".luarocks-build/fen/extensions/builtin_tools/read.lua",
         ["fen.extensions.builtin_tools.registry"] = ".luarocks-build/fen/extensions/builtin_tools/registry.lua",
         ["fen.extensions.builtin_tools.truncate"] = ".luarocks-build/fen/extensions/builtin_tools/truncate.lua",
         ["fen.extensions.builtin_tools.util"] = ".luarocks-build/fen/extensions/builtin_tools/util.lua",
         ["fen.extensions.builtin_tools.write"] = ".luarocks-build/fen/extensions/builtin_tools/write.lua",
      },
   },
}
