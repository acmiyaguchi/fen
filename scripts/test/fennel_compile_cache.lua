-- Fingerprinted generated-Lua cache for source-checkout Fennel tests.
--
-- Busted's default --auto-insulate resets package.loaded between test files.
-- That isolation is correct, but it makes every file recompile unchanged .fnl
-- dependency closures. This helper wraps fennel.dofile so each VM still
-- executes every module while parse+compile can be served from disk.

local M = {}

local function read_all(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function write_all(path, data)
  local f, err = io.open(path, "wb")
  if not f then return nil, err end
  f:write(data)
  f:close()
  return true
end

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function mkdir_p(path)
  return os.execute("mkdir -p -- " .. shell_quote(path))
end

local function dirname(path)
  return path:match("^(.*)/[^/]*$") or "."
end

-- FNV-1a 64-bit. This is a cache fingerprint, not a security boundary.
local function hash_string(s)
  local h = 0xcbf29ce484222325
  for i = 1, #s do
    h = h ~ s:byte(i)
    h = h * 0x100000001b3
  end
  return string.format("%016x", h)
end

local function uses_macros(src)
  -- Macro module names are arbitrary compile-time expressions, and macro
  -- implementations may load further dependencies. Without compiler-provided
  -- dependency data there is no sound cache key for these forms, so prefer a
  -- conservative bypass over serving stale generated Lua.
  return src:find("import%-macros") ~= nil or src:find("require%-macros") ~= nil
end

local cacheable_options = {
  allowedGlobals = true,
  correlate = true,
  filename = true,
  indent = true,
  lua = true,
  luaTarget = true,
  ["lua-target"] = true,
  ["module-name"] = true,
  requireAsInclude = true,
  source = true,
  useMetadata = true,
}

local function stable_value(value, seen)
  local kind = type(value)
  if kind == "nil" then return "nil" end
  if kind == "boolean" then return value and "true" or "false" end
  if kind == "number" then return string.format("number:%a", value) end
  if kind == "string" then return "string:" .. #value .. ":" .. value end
  if kind ~= "table" then return nil, "unsupported option value type: " .. kind end
  if getmetatable(value) ~= nil then return nil, "option table has a metatable" end
  seen = seen or {}
  if seen[value] then return nil, "cyclic option table" end
  seen[value] = true
  local entries = {}
  for key, item in pairs(value) do
    local encoded_key, key_err = stable_value(key, seen)
    if not encoded_key then seen[value] = nil; return nil, key_err end
    local encoded_item, item_err = stable_value(item, seen)
    if not encoded_item then seen[value] = nil; return nil, item_err end
    table.insert(entries, encoded_key .. "=" .. encoded_item)
  end
  seen[value] = nil
  table.sort(entries)
  return "table:{" .. table.concat(entries, ",") .. "}"
end

local function option_token(opts)
  local parts = {}
  for key, value in pairs(opts or {}) do
    if not cacheable_options[key] then
      return nil, "unknown compile option: " .. tostring(key)
    end
    local encoded, err = stable_value(value)
    if not encoded then return nil, err end
    table.insert(parts, tostring(key) .. "=" .. encoded)
  end
  table.sort(parts)
  return table.concat(parts, "\n")
end

local function default_cache_dir()
  local env = os.getenv("FEN_TEST_COMPILE_CACHE_DIR")
  if env and env ~= "" then return env end
  local xdg = os.getenv("XDG_CACHE_HOME")
  if xdg and xdg ~= "" then return xdg .. "/fen/fennel-compile-cache" end
  local home = os.getenv("HOME")
  if home and home ~= "" then return home .. "/.cache/fen/fennel-compile-cache" end
  return "tmp/fennel-compile-cache"
end

local function cache_paths(cache_dir, key)
  local shard = key:sub(1, 2)
  local dir = cache_dir .. "/" .. shard
  return dir, dir .. "/" .. key .. ".lua"
end

local function atomic_write(path, data)
  mkdir_p(dirname(path))
  local tmp = string.format("%s.tmp.%d.%06d", path, os.time(), math.random(100000, 999999))
  local ok, err = write_all(tmp, data)
  if not ok then return nil, err end
  local renamed, rename_err = os.rename(tmp, path)
  if not renamed then
    os.remove(tmp)
    return nil, rename_err
  end
  return true
end

function M.make_key(fennel, filename, opts, src)
  local options, options_err = option_token(opts)
  if not options then return nil, options_err end
  local key_material = table.concat({
    "fen-fnl-cache-v1",
    "fennel=" .. tostring(fennel.version or fennel["runtime-version"] or ""),
    "file=" .. tostring(filename),
    "source=" .. tostring(#src) .. ":" .. hash_string(src),
    "options=" .. options,
    "macro-path=" .. tostring(fennel["macro-path"] or fennel.macroPath or ""),
  }, "\n")
  return hash_string(key_material), key_material
end

function M.install(fennel, opts)
  opts = opts or {}
  if os.getenv("FEN_TEST_COMPILE_CACHE") == "0" and not opts.force then
    return {enabled = false, stats = {hits = 0, misses = 0, writes = 0, bypasses = 0}}
  end

  local original_dofile = fennel.dofile
  local original_dofile_camel = fennel.doFile
  local cache_dir = opts.cache_dir or default_cache_dir()
  local stats = {hits = 0, misses = 0, writes = 0, bypasses = 0, errors = 0}
  local stats_path = os.getenv("FEN_TEST_COMPILE_CACHE_STATS")
  local write_stats = nil

  if stats_path and stats_path ~= "" then
    write_stats = function()
      local lines = {
        "enabled=true",
        "cache_dir=" .. cache_dir,
        "hits=" .. tostring(stats.hits),
        "misses=" .. tostring(stats.misses),
        "writes=" .. tostring(stats.writes),
        "bypasses=" .. tostring(stats.bypasses),
        "errors=" .. tostring(stats.errors),
      }
      write_all(stats_path, table.concat(lines, "\n") .. "\n")
    end
    stats.write_stats = write_stats
    write_stats()
  end

  local function cached_dofile(filename, compile_opts, ...)
    -- Macro modules use Fennel's compiler environment machinery. Keep that
    -- path on the stock loader for the prototype; runtime modules still key on
    -- macro source fingerprints so edits invalidate dependent generated Lua.
    if compile_opts and compile_opts.env then
      stats.bypasses = stats.bypasses + 1
      if write_stats then write_stats() end
      return original_dofile(filename, compile_opts, ...)
    end

    local src = read_all(filename)
    if not src then
      stats.bypasses = stats.bypasses + 1
      if write_stats then write_stats() end
      return original_dofile(filename, compile_opts, ...)
    end

    if uses_macros(src) then
      stats.bypasses = stats.bypasses + 1
      if write_stats then write_stats() end
      return original_dofile(filename, compile_opts, ...)
    end

    local opts_copy = {}
    for k, v in pairs(compile_opts or {}) do opts_copy[k] = v end
    opts_copy.filename = filename

    local key = M.make_key(fennel, filename, opts_copy, src)
    if not key then
      stats.bypasses = stats.bypasses + 1
      if write_stats then write_stats() end
      return original_dofile(filename, compile_opts, ...)
    end
    local _, cache_path = cache_paths(cache_dir, key)
    local lua_source = read_all(cache_path)
    local from_cache = lua_source ~= nil
    if from_cache then
      stats.hits = stats.hits + 1
    else
      stats.misses = stats.misses + 1
      local ok, compiled = pcall(fennel["compile-string"] or fennel.compileString, src, opts_copy)
      if not ok then error(compiled, 0) end
      lua_source = compiled
      local wrote = atomic_write(cache_path, lua_source)
      if wrote then stats.writes = stats.writes + 1 else stats.errors = stats.errors + 1 end
    end

    local loader, load_err = (fennel["load-code"] or fennel.loadCode)(lua_source, nil, "@" .. filename)
    if not loader and from_cache then
      stats.errors = stats.errors + 1
      stats.misses = stats.misses + 1
      os.remove(cache_path)
      local ok, compiled = pcall(fennel["compile-string"] or fennel.compileString, src, opts_copy)
      if not ok then error(compiled, 0) end
      lua_source = compiled
      atomic_write(cache_path, lua_source)
      loader, load_err = (fennel["load-code"] or fennel.loadCode)(lua_source, nil, "@" .. filename)
    end
    if write_stats then write_stats() end
    if not loader then error(load_err, 0) end
    opts_copy.filename = nil
    return loader(...)
  end

  fennel.dofile = cached_dofile
  fennel.doFile = cached_dofile

  return {
    enabled = true,
    cache_dir = cache_dir,
    stats = stats,
    original_dofile = original_dofile,
    original_dofile_camel = original_dofile_camel,
    write_stats = stats.write_stats,
  }
end

return M
