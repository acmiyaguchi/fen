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
  local called, wrote, write_err = pcall(f.write, f, data)
  if not called or not wrote then
    pcall(f.close, f)
    return nil, called and write_err or wrote
  end
  local close_called, closed, close_err = pcall(f.close, f)
  if not close_called or not closed then
    return nil, close_called and close_err or closed
  end
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

local function fingerprint_field(value)
  local text = tostring(value)
  return tostring(#text) .. ":" .. text
end

-- Find compile-time dependencies from parsed forms. Runtime source embeds
-- include targets, while every unquoted require in a macro module runs in the
-- compiler environment. Forms which cannot be followed soundly bypass caching.
local function compile_dependencies(fennel, src, filename, mode, opts)
  local parser = fennel.parser
  local string_stream = fennel["string-stream"] or fennel.stringStream
  local listp = fennel["list?"]
  if not parser or not string_stream then return nil, "parser unavailable" end

  local dependencies = {}
  local function is_list(node)
    if type(node) ~= "table" then return false end
    if listp then return listp(node) end
    return node.closer == string.byte(")")
  end
  local function module_name(value)
    if type(value) ~= "string" then return nil end
    return value
  end
  local function add_dependency(kind, name, dependency_mode)
    dependencies[kind .. "\0" .. dependency_mode .. "\0" .. name] = {
      kind = kind,
      name = name,
      mode = dependency_mode,
    }
  end
  local function walk(node, quote_depth)
    if type(node) ~= "table" then return true end
    quote_depth = quote_depth or 0

    if is_list(node) then
      local head = tostring(node[1])
      if head == "quote" then
        for i = 2, #node do
          local ok, err = walk(node[i], quote_depth + 1)
          if not ok then return nil, err end
        end
        return true
      elseif quote_depth > 0 then
        -- Quoted forms can be returned by macros and compiled at their call
        -- sites. Track special forms which would still run at compile time,
        -- while ordinary quoted require stays a runtime dependency.
        if head == "eval-compiler" then
          return nil, "quoted eval-compiler is not cacheable"
        elseif head == "macro" or head == "macros" then
          return nil, "quoted inline macros are not cacheable"
        elseif head == "require-macros" then
          local name = #node == 2 and module_name(node[2])
          if not name then return nil, "dynamic quoted require-macros" end
          add_dependency("macro", name, "macro")
          return true
        elseif head == "import-macros" then
          local name = #node == 3 and module_name(node[3])
          if not name then return nil, "dynamic quoted import-macros" end
          add_dependency("macro", name, "macro")
          return true
        elseif head == "include" then
          local name = #node == 2 and module_name(node[2])
          if not name then return nil, "dynamic quoted include" end
          add_dependency("include", name, "runtime")
          return true
        elseif head == "require" and opts.requireAsInclude then
          local name = #node == 2 and module_name(node[2])
          if not name then return nil, "dynamic quoted compile-time require" end
          add_dependency("include", name, "runtime")
          return true
        end
        local depth = quote_depth
        if head == "unquote" or head == "unquote-splicing" then
          depth = quote_depth - 1
        end
        for i = 1, #node do
          local ok, err = walk(node[i], depth)
          if not ok then return nil, err end
        end
        return true
      elseif head == "eval-compiler" then
        return nil, "eval-compiler is not cacheable"
      elseif head == "macro" or head == "macros" then
        return nil, "inline macros are not cacheable"
      elseif head == "require-macros" then
        local name = #node == 2 and module_name(node[2])
        if not name then return nil, "dynamic require-macros" end
        add_dependency("macro", name, "macro")
        return true
      elseif head == "import-macros" then
        local name = #node == 3 and module_name(node[3])
        if not name then return nil, "dynamic import-macros" end
        add_dependency("macro", name, "macro")
        return true
      elseif head == "include" then
        local name = #node == 2 and module_name(node[2])
        if not name then return nil, "dynamic include" end
        add_dependency("include", name, mode)
        return true
      elseif head == "require" and (mode == "macro" or opts.requireAsInclude) then
        local name = #node == 2 and module_name(node[2])
        if not name then return nil, "dynamic compile-time require" end
        if mode == "macro" then
          add_dependency("macro", name, "macro")
        else
          add_dependency("include", name, "runtime")
        end
        return true
      end
    end

    for key, value in pairs(node) do
      if type(key) == "table" then
        local key_ok, key_err = walk(key, quote_depth)
        if not key_ok then return nil, key_err end
      end
      local value_ok, value_err = walk(value, quote_depth)
      if not value_ok then return nil, value_err end
    end
    return true
  end

  local ok, parse_err = pcall(function()
    for _, form in parser(string_stream(src), filename) do
      local walked, walk_err = walk(form, 0)
      if not walked then error(walk_err, 0) end
    end
  end)
  if not ok then return nil, parse_err end
  return dependencies
end

local function searched_source_path(fennel, module_name, path)
  local search = fennel["search-module"] or fennel.searchModule
  if not search then return nil end
  local first, second = search(module_name, path)
  -- Fennel returns the filename first; accepting it second keeps this helper
  -- compatible with compiler implementations that return loader, filename.
  if type(first) == "string" and read_all(first) then return first end
  if type(second) == "string" and read_all(second) then return second end
  return nil
end

local function macro_source_path(fennel, module_name)
  return searched_source_path(fennel, module_name,
                              fennel["macro-path"] or fennel.macroPath or "")
end

local function included_source_path(fennel, module_name)
  local fennel_path = searched_source_path(fennel, module_name, fennel.path or "")
  if fennel_path then return fennel_path, "fennel" end
  local lua_path = searched_source_path(fennel, module_name, package.path or "")
  if lua_path then return lua_path, "lua" end
  return nil
end

function M.dependency_fingerprint(fennel, src, filename, opts)
  opts = opts or {}
  local stack = {[filename] = true}
  local function fingerprint_source(source, source_name, mode)
    local dependencies, err = compile_dependencies(fennel, source, source_name, mode, opts)
    if not dependencies then return nil, err end
    local parts = {}
    for _, dependency in pairs(dependencies) do
      local path, source_kind
      if dependency.kind == "macro" then
        path, source_kind = macro_source_path(fennel, dependency.name), "fennel"
      else
        path, source_kind = included_source_path(fennel, dependency.name)
      end
      if not path then
        return nil, "compile-time module not found: " .. dependency.name
      end
      if stack[path] then return nil, "cyclic compile-time dependency: " .. path end
      stack[path] = true
      local dependency_source = read_all(path)
      if not dependency_source then
        stack[path] = nil
        return nil, "compile-time source unreadable: " .. path
      end
      local nested = ""
      if source_kind == "fennel" then
        local nested_err
        nested, nested_err = fingerprint_source(dependency_source, path, dependency.mode)
        if not nested then
          stack[path] = nil
          return nil, nested_err
        end
      end
      stack[path] = nil
      table.insert(parts, table.concat({
        fingerprint_field(dependency.kind),
        fingerprint_field(dependency.name),
        fingerprint_field(source_kind),
        fingerprint_field(path),
        fingerprint_field(hash_string(dependency_source)),
        fingerprint_field(nested),
      }))
    end
    table.sort(parts)
    return table.concat(parts, "\n")
  end
  return fingerprint_source(src, filename, "runtime")
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
  -- Include the process id so parallel test processes never write through
  -- one another's temporary path before the atomic rename.
  local stat = read_all("/proc/self/stat") or ""
  local pid = stat:match("^(%d+)") or tostring({}):gsub("table: ", "")
  local tmp = string.format("%s.tmp.%s.%d.%06d", path, pid, os.time(), math.random(100000, 999999))
  local ok, err = write_all(tmp, data)
  if not ok then
    os.remove(tmp)
    return nil, err
  end
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
  local dependencies, dependency_err = M.dependency_fingerprint(fennel, src, filename, opts)
  if not dependencies then return nil, dependency_err end
  local key_material = table.concat({
    "fen-fnl-cache-v3",
    "fennel=" .. tostring(fennel.version or fennel["runtime-version"] or ""),
    "file=" .. tostring(filename),
    "source=" .. tostring(#src) .. ":" .. hash_string(src),
    "options=" .. options,
    "fennel-path=" .. tostring(fennel.path or ""),
    "macro-path=" .. tostring(fennel["macro-path"] or fennel.macroPath or ""),
    "compile-dependencies=" .. dependencies,
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
      local wrote = atomic_write(cache_path, lua_source)
      if wrote then stats.writes = stats.writes + 1 else stats.errors = stats.errors + 1 end
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
