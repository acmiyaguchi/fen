package = "fen-ext-builtin-commands"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
   dir = "fen/extensions/builtin-commands",
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
if [ -n "${FEN_WORKSPACE:-}" ] && [ -f "$FEN_WORKSPACE/scripts/fennel-build.fnl" ]; then
  "${FENNEL:-fennel}" "$FEN_WORKSPACE/scripts/fennel-build.fnl" --lrbuild
else
  rm -rf .lrbuild
  SNAKE=builtin_commands
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
fi
   ]],
   install = {
      lua = {
         ["fen.extensions.builtin_commands.commands.extension"] = ".lrbuild/extensions/builtin_commands/commands/extension.lua",
         ["fen.extensions.builtin_commands.commands.help"] = ".lrbuild/extensions/builtin_commands/commands/help.lua",
         ["fen.extensions.builtin_commands.commands.model"] = ".lrbuild/extensions/builtin_commands/commands/model.lua",
         ["fen.extensions.builtin_commands.commands.prompt"] = ".lrbuild/extensions/builtin_commands/commands/prompt.lua",
         ["fen.extensions.builtin_commands.commands.queue"] = ".lrbuild/extensions/builtin_commands/commands/queue.lua",
         ["fen.extensions.builtin_commands.commands.session"] = ".lrbuild/extensions/builtin_commands/commands/session.lua",
         ["fen.extensions.builtin_commands.commands.status"] = ".lrbuild/extensions/builtin_commands/commands/status.lua",
         ["fen.extensions.builtin_commands"] = ".lrbuild/extensions/builtin_commands/init.lua",
         ["fen.extensions.builtin_commands.manifest"] = ".lrbuild/extensions/builtin_commands/manifest.lua",
         ["fen.extensions.builtin_commands.state.extensions"] = ".lrbuild/extensions/builtin_commands/state/extensions.lua",
         ["fen.extensions.builtin_commands.state.prompt"] = ".lrbuild/extensions/builtin_commands/state/prompt.lua",
         ["fen.extensions.builtin_commands.state.queue"] = ".lrbuild/extensions/builtin_commands/state/queue.lua",
         ["fen.extensions.builtin_commands.state.status"] = ".lrbuild/extensions/builtin_commands/state/status.lua",
         ["fen.extensions.builtin_commands.util"] = ".lrbuild/extensions/builtin_commands/util.lua",
      },
   },
}
