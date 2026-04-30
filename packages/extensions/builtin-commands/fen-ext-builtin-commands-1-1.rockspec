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
   type = "builtin",
   modules = {
      ["fen.extensions.builtin_commands.commands.extension"] = "dist/fen/extensions/builtin_commands/commands/extension.lua",
      ["fen.extensions.builtin_commands.commands.help"] = "dist/fen/extensions/builtin_commands/commands/help.lua",
      ["fen.extensions.builtin_commands.commands.model"] = "dist/fen/extensions/builtin_commands/commands/model.lua",
      ["fen.extensions.builtin_commands.commands.prompt"] = "dist/fen/extensions/builtin_commands/commands/prompt.lua",
      ["fen.extensions.builtin_commands.commands.queue"] = "dist/fen/extensions/builtin_commands/commands/queue.lua",
      ["fen.extensions.builtin_commands.commands.session"] = "dist/fen/extensions/builtin_commands/commands/session.lua",
      ["fen.extensions.builtin_commands.commands.status"] = "dist/fen/extensions/builtin_commands/commands/status.lua",
      ["fen.extensions.builtin_commands"] = "dist/fen/extensions/builtin_commands/init.lua",
      ["fen.extensions.builtin_commands.manifest"] = "dist/fen/extensions/builtin_commands/manifest.lua",
      ["fen.extensions.builtin_commands.state.extensions"] = "dist/fen/extensions/builtin_commands/state/extensions.lua",
      ["fen.extensions.builtin_commands.state.prompt"] = "dist/fen/extensions/builtin_commands/state/prompt.lua",
      ["fen.extensions.builtin_commands.state.queue"] = "dist/fen/extensions/builtin_commands/state/queue.lua",
      ["fen.extensions.builtin_commands.state.status"] = "dist/fen/extensions/builtin_commands/state/status.lua",
      ["fen.extensions.builtin_commands.util"] = "dist/fen/extensions/builtin_commands/util.lua",
   },
}
