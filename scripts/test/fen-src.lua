-- Entry point for scripts/test/fen-src: the busted bootstrap, then fen.main.
dofile(arg[0]:match("^(.*)/[^/]*$") .. "/busted-helper.lua")
require("fen.main")
