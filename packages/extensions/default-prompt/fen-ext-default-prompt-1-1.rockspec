package = "fen-ext-default-prompt"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
   dir = "fen/packages/extensions/default-prompt",
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
      ["fen.extensions.default_prompt"] = "dist/fen/extensions/default_prompt/init.lua",
      ["fen.extensions.default_prompt.manifest"] = "dist/fen/extensions/default_prompt/manifest.lua",
   },
}
