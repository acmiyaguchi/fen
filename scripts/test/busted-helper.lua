-- Bootstrap for busted: install the Fennel package loader so package-local
-- .fnl test files can `require :fen.core.llm` etc. and resolve directly to
-- package src/*.fnl with no compile-to-Lua step.
--
-- fennel.install() adds a searcher to package.searchers; that searcher uses
-- fennel.path (NOT package.path), so we extend fennel.path here. Keeping the
-- Lua-side package.path untouched means the Lua searcher won't see .fnl files
-- and try to parse them as Lua.
local fennel = require("fennel")

-- Resolve the checkout from this file so scripts/test/fen-src can reuse the
-- bootstrap from any working directory.
local root = debug.getinfo(1, "S").source:match("^@(.*)/scripts/test/[^/]*$")
local function at(path) return root and (root .. "/" .. path) or path end
local function shell_quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

local src_dirs = {}
do
  local p = io.popen("find " .. shell_quote(at("packages")) .. " -path '*/src' -type d | sort")
  if p then
    for dir in p:lines() do
      table.insert(src_dirs, dir)
    end
    p:close()
  end
end

local paths = {}
for _, pattern in ipairs({"/?.fnl", "/?/init.fnl"}) do
  for _, dir in ipairs(src_dirs) do
    table.insert(paths, dir .. pattern)
  end
end

local package_paths = table.concat(paths, ";")
fennel.path = package_paths .. ";" .. fennel.path
fennel["macro-path"] = package_paths .. ";" .. fennel["macro-path"]

local compile_cache = dofile(at("scripts/test/fennel_compile_cache.lua"))
compile_cache.install(fennel)

fennel.install()

-- Flat-layout first-party extensions live below extensions/**/
-- without a `src/fen/extensions/<snake>/` mirror. fennel.path's `?`
-- substitution can't strip the namespace prefix from the module name, so
-- install a custom searcher that maps `fen.extensions.<snake>[.<rest>]`
-- back to the manifest-bearing extension dir. Logic lives in
-- fen.util.flat_extensions and is shared with the single-file launcher.
local flat_ext = require("fen.util.flat_extensions")
flat_ext["install!"]({
  roots = {at("extensions")},
  fennel = fennel,
  position = 2,
})

-- Prepend package dist dirs when scripts/test/run-tests.sh has produced local
-- native test modules there. This lets source-checkout tests find fresh
-- fen_http.so / termbox2.so without installing rocks.
do
  local dist_cpath = {}
  local p = io.popen("find " .. shell_quote(at("packages")) .. " " .. shell_quote(at("extensions")) .. " -path '*/dist' -type d | sort")
  if p then
    for dir in p:lines() do
      table.insert(dist_cpath, dir .. "/?.so")
    end
    p:close()
  end
  if #dist_cpath > 0 then
    package.cpath = table.concat(dist_cpath, ";") .. ";" .. package.cpath
  end
end

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
