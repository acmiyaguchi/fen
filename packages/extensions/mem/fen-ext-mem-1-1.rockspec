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
   type = "builtin",
   modules = {
      ["fen.extensions.mem"] = "dist/fen/extensions/mem/init.lua",
      ["fen.extensions.mem.manifest"] = "dist/fen/extensions/mem/manifest.lua",
      ["fen.extensions.mem.state"] = "dist/fen/extensions/mem/state.lua",
   },
}
