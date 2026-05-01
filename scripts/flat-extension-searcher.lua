-- Custom Fennel/Lua searcher for flat-layout first-party extensions.
--
-- After issue #67 Phase A, manifest-shaped extensions live as flat sources
-- under packages/extensions/<kebab>/{manifest.fnl,init.fnl,...} with no
-- `src/fen/extensions/<snake>/` mirror. The runtime contract still uses
-- `require :fen.extensions.<snake>...`, so test and build tooling needs a
-- searcher that maps that namespace back to the flat source location.
--
-- Lua's `?`-substitution can't strip the `fen/extensions/<snake>/` prefix
-- from the module name, so we register a real searcher.
--
-- The map snake→kebab is built once by walking packages/extensions/* and
-- text-matching :name :<snake> from each manifest.fnl. Manifests are literal
-- tables so a regex is safe — no Fennel eval needed at bootstrap time.

local M = {}

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function file_exists(path)
  local f = io.open(path, "r")
  if not f then return false end
  f:close()
  return true
end

local function parse_manifest_name(text)
  if not text then return nil end
  -- :name :foo  or  :name "foo"  or  name = "foo"
  return text:match(":name%s+:([%w_%-]+)")
      or text:match(":name%s+\"([^\"]+)\"")
      or text:match("name%s*=%s*\"([^\"]+)\"")
end

-- Walk packages/extensions/* relative to `root` and build a snake→kebab map.
function M.build_map(root)
  root = root or "."
  local map = {}
  local p = io.popen("find " .. root .. "/packages/extensions -mindepth 1 -maxdepth 1 -type d 2>/dev/null")
  if not p then return map end
  for dir in p:lines() do
    local kebab = dir:match("([^/]+)$")
    local manifest_path = dir .. "/manifest.fnl"
    if not file_exists(manifest_path) then
      manifest_path = dir .. "/manifest.lua"
    end
    if file_exists(manifest_path) then
      local snake = parse_manifest_name(read_file(manifest_path))
      if snake then
        map[snake] = dir
      elseif kebab then
        -- Fallback: kebab→snake transform.
        map[kebab:gsub("%-", "_")] = dir
      end
    end
  end
  p:close()
  return map
end

-- Resolve `fen.extensions.<snake>[.<rest>]` to a .fnl path under the flat
-- extension dir. Returns the path, or nil if no candidate exists on disk.
function M.resolve_fnl(map, modname)
  local snake, rest = modname:match("^fen%.extensions%.([^.]+)%.?(.*)$")
  if not snake then return nil end
  local dir = map[snake]
  if not dir then return nil end
  if rest == "" then
    local candidate = dir .. "/init.fnl"
    if file_exists(candidate) then return candidate end
    return nil
  end
  local sub = rest:gsub("%.", "/")
  local candidates = { dir .. "/" .. sub .. ".fnl",
                       dir .. "/" .. sub .. "/init.fnl" }
  for _, c in ipairs(candidates) do
    if file_exists(c) then return c end
  end
  return nil
end

-- Build a Lua searcher that loads .fnl files via Fennel for matching modules.
-- Returns a function suitable to insert into package.searchers.
--
-- Defers to package.preload[modname] when set so callers (notably tests
-- that stub modules via package.preload) can override resolution. With
-- luarocks installed, its loader takes searcher slot 1 and shifts the
-- standard preload searcher off the front; without this guard, this
-- searcher would resolve before preload runs.
function M.lua_searcher(fennel, map)
  return function(modname)
    if package.preload[modname] then return nil end
    local path = M.resolve_fnl(map, modname)
    if not path then return nil end
    local loader = function()
      return fennel.dofile(path)
    end
    return loader, path
  end
end

return M
