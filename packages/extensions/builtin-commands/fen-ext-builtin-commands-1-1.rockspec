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
mkdir -p .luarocks-build/fen/extensions/builtin_commands/commands
fennel --compile src/fen/extensions/builtin_commands/commands/extension.fnl > .luarocks-build/fen/extensions/builtin_commands/commands/extension.lua
mkdir -p .luarocks-build/fen/extensions/builtin_commands/commands
fennel --compile src/fen/extensions/builtin_commands/commands/help.fnl > .luarocks-build/fen/extensions/builtin_commands/commands/help.lua
mkdir -p .luarocks-build/fen/extensions/builtin_commands/commands
fennel --compile src/fen/extensions/builtin_commands/commands/model.fnl > .luarocks-build/fen/extensions/builtin_commands/commands/model.lua
mkdir -p .luarocks-build/fen/extensions/builtin_commands/commands
fennel --compile src/fen/extensions/builtin_commands/commands/prompt.fnl > .luarocks-build/fen/extensions/builtin_commands/commands/prompt.lua
mkdir -p .luarocks-build/fen/extensions/builtin_commands/commands
fennel --compile src/fen/extensions/builtin_commands/commands/queue.fnl > .luarocks-build/fen/extensions/builtin_commands/commands/queue.lua
mkdir -p .luarocks-build/fen/extensions/builtin_commands/commands
fennel --compile src/fen/extensions/builtin_commands/commands/session.fnl > .luarocks-build/fen/extensions/builtin_commands/commands/session.lua
mkdir -p .luarocks-build/fen/extensions/builtin_commands/commands
fennel --compile src/fen/extensions/builtin_commands/commands/status.fnl > .luarocks-build/fen/extensions/builtin_commands/commands/status.lua
mkdir -p .luarocks-build/fen/extensions/builtin_commands
fennel --compile src/fen/extensions/builtin_commands/init.fnl > .luarocks-build/fen/extensions/builtin_commands/init.lua
mkdir -p .luarocks-build/fen/extensions/builtin_commands
fennel --compile src/fen/extensions/builtin_commands/manifest.fnl > .luarocks-build/fen/extensions/builtin_commands/manifest.lua
mkdir -p .luarocks-build/fen/extensions/builtin_commands/state
fennel --compile src/fen/extensions/builtin_commands/state/extensions.fnl > .luarocks-build/fen/extensions/builtin_commands/state/extensions.lua
mkdir -p .luarocks-build/fen/extensions/builtin_commands/state
fennel --compile src/fen/extensions/builtin_commands/state/prompt.fnl > .luarocks-build/fen/extensions/builtin_commands/state/prompt.lua
mkdir -p .luarocks-build/fen/extensions/builtin_commands/state
fennel --compile src/fen/extensions/builtin_commands/state/queue.fnl > .luarocks-build/fen/extensions/builtin_commands/state/queue.lua
mkdir -p .luarocks-build/fen/extensions/builtin_commands/state
fennel --compile src/fen/extensions/builtin_commands/state/status.fnl > .luarocks-build/fen/extensions/builtin_commands/state/status.lua
mkdir -p .luarocks-build/fen/extensions/builtin_commands
fennel --compile src/fen/extensions/builtin_commands/util.fnl > .luarocks-build/fen/extensions/builtin_commands/util.lua
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
