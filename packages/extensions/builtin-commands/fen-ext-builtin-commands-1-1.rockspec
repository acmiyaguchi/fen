package = "fen-ext-builtin-commands"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
   dir = "fen/packages/extensions/builtin-commands",
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
         ["fen.extensions.builtin_commands.commands.extension"] = ".luarocks-build/fen/extensions/builtin_commands/commands/extension.lua",
         ["fen.extensions.builtin_commands.commands.help"] = ".luarocks-build/fen/extensions/builtin_commands/commands/help.lua",
         ["fen.extensions.builtin_commands.commands.model"] = ".luarocks-build/fen/extensions/builtin_commands/commands/model.lua",
         ["fen.extensions.builtin_commands.commands.prompt"] = ".luarocks-build/fen/extensions/builtin_commands/commands/prompt.lua",
         ["fen.extensions.builtin_commands.commands.queue"] = ".luarocks-build/fen/extensions/builtin_commands/commands/queue.lua",
         ["fen.extensions.builtin_commands.commands.session"] = ".luarocks-build/fen/extensions/builtin_commands/commands/session.lua",
         ["fen.extensions.builtin_commands.commands.status"] = ".luarocks-build/fen/extensions/builtin_commands/commands/status.lua",
         ["fen.extensions.builtin_commands"] = ".luarocks-build/fen/extensions/builtin_commands/init.lua",
         ["fen.extensions.builtin_commands.manifest"] = ".luarocks-build/fen/extensions/builtin_commands/manifest.lua",
         ["fen.extensions.builtin_commands.state.extensions"] = ".luarocks-build/fen/extensions/builtin_commands/state/extensions.lua",
         ["fen.extensions.builtin_commands.state.prompt"] = ".luarocks-build/fen/extensions/builtin_commands/state/prompt.lua",
         ["fen.extensions.builtin_commands.state.queue"] = ".luarocks-build/fen/extensions/builtin_commands/state/queue.lua",
         ["fen.extensions.builtin_commands.state.status"] = ".luarocks-build/fen/extensions/builtin_commands/state/status.lua",
         ["fen.extensions.builtin_commands.util"] = ".luarocks-build/fen/extensions/builtin_commands/util.lua",
      },
   },
}
