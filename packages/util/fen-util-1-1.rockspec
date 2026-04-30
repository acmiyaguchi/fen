package = "fen-util"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
   dir = "fen/packages/util",
}

description = {
   summary = "fen utility modules",
   license = "MIT",
}

dependencies = {
   "lua >= 5.4",
   "lua-cjson >= 2.1",
   "lua-curl >= 0.3",
   "fennel >= 1.4",
}

test_dependencies = {
   "busted >= 2.0",
}

build = {
   type = "builtin",
   modules = {
      ["fen.util.base64"] = "dist/fen/util/base64.lua",
      ["fen.util.checksum"] = "dist/fen/util/checksum.lua",
      ["fen.util.http"] = "dist/fen/util/http.lua",
      ["fen.util.json"] = "dist/fen/util/json.lua",
      ["fen.util.log"] = "dist/fen/util/log.lua",
      ["fen.util.path"] = "dist/fen/util/path.lua",
      ["fen.util.process"] = "dist/fen/util/process.lua",
      ["fen.util.sse"] = "dist/fen/util/sse.lua",
   },
}
