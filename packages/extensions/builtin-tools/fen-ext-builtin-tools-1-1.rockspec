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
   type = "builtin",
   modules = {
      ["fen.extensions.builtin_tools.bash"] = "dist/fen/extensions/builtin_tools/bash.lua",
      ["fen.extensions.builtin_tools.edit"] = "dist/fen/extensions/builtin_tools/edit.lua",
      ["fen.extensions.builtin_tools.find"] = "dist/fen/extensions/builtin_tools/find.lua",
      ["fen.extensions.builtin_tools.grep"] = "dist/fen/extensions/builtin_tools/grep.lua",
      ["fen.extensions.builtin_tools"] = "dist/fen/extensions/builtin_tools/init.lua",
      ["fen.extensions.builtin_tools.ls"] = "dist/fen/extensions/builtin_tools/ls.lua",
      ["fen.extensions.builtin_tools.manifest"] = "dist/fen/extensions/builtin_tools/manifest.lua",
      ["fen.extensions.builtin_tools.read"] = "dist/fen/extensions/builtin_tools/read.lua",
      ["fen.extensions.builtin_tools.registry"] = "dist/fen/extensions/builtin_tools/registry.lua",
      ["fen.extensions.builtin_tools.truncate"] = "dist/fen/extensions/builtin_tools/truncate.lua",
      ["fen.extensions.builtin_tools.util"] = "dist/fen/extensions/builtin_tools/util.lua",
      ["fen.extensions.builtin_tools.write"] = "dist/fen/extensions/builtin_tools/write.lua",
   },
}
