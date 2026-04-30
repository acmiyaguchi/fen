#!/bin/sh
set -eu

: "${FEN_PKG:?FEN_PKG is required}"
: "${FEN_LUA:?FEN_LUA is required}"
: "${FEN_LUA_ENV:?FEN_LUA_ENV is required}"
: "${FEN_VERSION:?FEN_VERSION is required}"
: "${FEN_ARTIFACT_SYSTEM:?FEN_ARTIFACT_SYSTEM is required}"

if [ "$#" -ne 1 ]; then
  echo "usage: nix-bundle-linux.sh OUT_DIR" >&2
  exit 2
fi

out=$1
name="fen-${FEN_VERSION}-${FEN_ARTIFACT_SYSTEM}"
root="$PWD/$name"

mkdir -p \
  "$root/bin" \
  "$root/lib" \
  "$root/libexec" \
  "$root/lib/lua/5.4" \
  "$root/share/lua/5.4" \
  "$root/share/fen/bin"

cp -RL "$FEN_PKG/share/lua/5.4"/. "$root/share/lua/5.4/"
cp -RL "$FEN_PKG/lib/lua/5.4"/. "$root/lib/lua/5.4/"
cp "$FEN_PKG/share/fen/bin/fen.lua" "$root/share/fen/bin/fen.lua"

# Copy the Lua interpreter itself plus the Lua modules supplied by nixpkgs
# rocks. The phase-1 Nix package can rely on store paths; this bundle is meant
# to be extracted elsewhere, so it carries the runtime module tree directly.
cp "$FEN_LUA/bin/lua" "$root/libexec/lua"
if [ -d "$FEN_LUA_ENV/share/lua/5.4" ]; then
  cp -RL "$FEN_LUA_ENV/share/lua/5.4"/. "$root/share/lua/5.4/"
fi
if [ -d "$FEN_LUA_ENV/lib/lua/5.4" ]; then
  cp -RL "$FEN_LUA_ENV/lib/lua/5.4"/. "$root/lib/lua/5.4/"
fi

# Copy shared-library dependencies reported by ldd for the bundled Lua
# executable and C modules. Iterate because copied libraries have their own
# dependencies. The wrapper below invokes the bundled ELF loader explicitly,
# avoiding an absolute /nix/store PT_INTERP path.
copy_deps() {
  while IFS= read -r elf; do
    ldd "$elf" 2>/dev/null \
      | awk '
          /=> \/nix\/store\// { print $3 }
          /^\/nix\/store\// { print $1 }
        ' \
      | while IFS= read -r lib; do
          if [ -n "$lib" ] && [ -f "$lib" ] && [ ! -e "$root/lib/$(basename "$lib")" ]; then
            cp -L "$lib" "$root/lib/$(basename "$lib")"
            echo copied > "$root/.deps-changed"
          fi
        done
  done <<EOF
$(find "$root" -type f \( -perm -0100 -o -name '*.so' -o -name '*.so.*' \))
EOF
  if [ -e "$root/.deps-changed" ]; then
    rm "$root/.deps-changed"
    return 0
  fi
  return 1
}

while copy_deps; do :; done

interp=$(ldd "$root/libexec/lua" | awk '/ld-linux|ld-musl/ { print $1; exit }')
interp_base=$(basename "$interp")

chmod -R u+rwX "$root"

# Drop Nix store RUNPATHs from copied ELF files. The launcher uses the bundled
# loader with --library-path, and these relative RPATHs keep direct
# execution/debugging pointed at the bundle too.
patchelf --set-rpath '$ORIGIN/../lib' "$root/libexec/lua"
while IFS= read -r so; do
  patchelf --set-rpath '$ORIGIN/../../../lib' "$so" 2>/dev/null || true
done <<EOF
$(find "$root/lib/lua/5.4" -type f \( -name '*.so' -o -name '*.so.*' \))
EOF

cat > "$root/bin/fen" <<EOF
#!/bin/sh
set -eu
BIN_DIR=\$(CDPATH= cd -- "\$(dirname -- "\$0")" && pwd)
ROOT=\$(dirname "\$BIN_DIR")
export LUA_PATH="\$ROOT/share/lua/5.4/?.lua;\$ROOT/share/lua/5.4/?/init.lua;\${LUA_PATH:-;;}"
export LUA_CPATH="\$ROOT/lib/lua/5.4/?.so;\${LUA_CPATH:-;;}"
LIB_PATH="\$ROOT/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "\$ROOT/lib/$interp_base" --library-path "\$LIB_PATH" "\$ROOT/libexec/lua" "\$ROOT/share/fen/bin/fen.lua" "\$@"
EOF
chmod -R u+rwX "$root"
chmod +x "$root/bin/fen" "$root/libexec/lua"

cat > "$root/README.txt" <<EOF
fen ${FEN_VERSION} portable Linux bundle (${FEN_ARTIFACT_SYSTEM})

Run with:

  ./bin/fen --help

This bundle carries Lua 5.4, fen's compiled Lua modules, Lua C modules,
and the shared libraries reported by ldd at build time. It is intended for
Linux distributions on the same architecture/ABI as the artifact name.
EOF

mkdir -p "$out"
tar czf "$out/$name.tar.gz" -C "$PWD" "$name"
