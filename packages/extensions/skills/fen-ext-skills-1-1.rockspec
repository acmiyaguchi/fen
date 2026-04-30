package = "fen-ext-skills"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
   dir = "fen/packages/extensions/skills",
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
      ["fen.extensions.skills.ignore"] = "dist/fen/extensions/skills/ignore.lua",
      ["fen.extensions.skills"] = "dist/fen/extensions/skills/init.lua",
      ["fen.extensions.skills.manifest"] = "dist/fen/extensions/skills/manifest.lua",
   },
}
