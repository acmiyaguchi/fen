-- Bootstrap for busted: install the Fennel package loader so .fnl test files
-- can `require :core.llm` etc. and resolve directly to src/*.fnl with no
-- compile-to-Lua step.
--
-- fennel.install() adds a searcher to package.searchers; that searcher uses
-- fennel.path (NOT package.path), so we extend fennel.path here. Keeping the
-- Lua-side package.path untouched means the Lua searcher won't see .fnl files
-- and try to parse them as Lua.
local fennel = require("fennel")
fennel.path = "./src/?.fnl;./src/?/init.fnl;./tests/?.fnl;" .. fennel.path
fennel.install()
