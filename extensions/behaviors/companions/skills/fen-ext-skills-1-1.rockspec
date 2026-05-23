package = "fen-ext-skills"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
   dir = "fen/extensions/behaviors/companions/skills",
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
   type = "command",
   build_command = [[
set -eu
emit_bundled_data() {
  out="$1"
  mkdir -p "$(dirname "$out")"
  "${LUA:-lua}" - "$out" <<'LUA'
local out = assert(arg[1], "missing output path")
local function read_all(path)
  local f = assert(io.open(path, "rb"))
  local data = f:read("*a")
  f:close()
  return data
end
local root = "bundled"
local p = io.popen("find " .. root .. " -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort", "r")
local lines = { "return {" }
if p then
  for dir in p:lines() do
    local skill = dir .. "/SKILL.md"
    local f = io.open(skill, "rb")
    if f then
      local content = f:read("*a")
      f:close()
      local name = dir:match("([^/]+)$") or dir
      table.insert(lines, "  { dir = " .. string.format("%q", name) .. ", file = \"SKILL.md\", content = " .. string.format("%q", content) .. " },")
    end
  end
  p:close()
end
lines[#lines + 1] = "}"
local f = assert(io.open(out, "wb"))
f:write(table.concat(lines, "\n"), "\n")
f:close()
LUA
}
if [ -n "${FEN_WORKSPACE:-}" ] && [ -f "$FEN_WORKSPACE/scripts/build/fennel-build.fnl" ]; then
  "${FENNEL:-fennel}" "$FEN_WORKSPACE/scripts/build/fennel-build.fnl" --lrbuild
else
  rm -rf .lrbuild
  SNAKE=skills
  find . -type f -name '*.fnl' \
    -not -path './tests/*' \
    -not -path './vendor/*' \
    -not -path './.lrbuild/*' \
    -not -path './dist/*' \
    | sort | while IFS= read -r src; do
    rel="${src#./}"
    out=".lrbuild/extensions/${SNAKE}/${rel%.fnl}.lua"
    mkdir -p "$(dirname "$out")"
    "${FENNEL:-fennel}" --compile "$src" > "$out"
  done
  emit_bundled_data .lrbuild/extensions/${SNAKE}/bundled_data.lua
fi
   ]],
   install = {
      lua = {
         ["fen.extensions.skills.bundled"] = ".lrbuild/extensions/skills/bundled.lua",
         ["fen.extensions.skills.bundled_data"] = ".lrbuild/extensions/skills/bundled_data.lua",
         ["fen.extensions.skills.ignore"] = ".lrbuild/extensions/skills/ignore.lua",
         ["fen.extensions.skills.state"] = ".lrbuild/extensions/skills/state.lua",
         ["fen.extensions.skills"] = ".lrbuild/extensions/skills/init.lua",
         ["fen.extensions.skills.manifest"] = ".lrbuild/extensions/skills/manifest.lua",
      },
   },
}
