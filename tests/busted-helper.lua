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
fennel["macro-path"] = "./tests/?.fnl;" .. fennel["macro-path"]
fennel.install()

-- Defensive guard: termbox2 grabs the controlling tty on require("termbox2"
-- ).init(). No test imports tui.tui today, but a future test could pull it
-- in transitively. Replace the module with a proxy that errors loudly so
-- the failure is obvious instead of a hung tty.
package.loaded["termbox2"] = setmetatable({}, {
  __index = function(_, k)
    error("termbox2 must not be loaded under busted (got access to '"
          .. tostring(k) .. "')")
  end,
})
