# Exercise the public overlay without our test-toolchain overlay.
{ pkgs, nixpkgs, system, overlay }:
let
  consumer = import nixpkgs {
    inherit system;
    overlays = [ overlay ];
  };
  fen = consumer.fen;
in
assert fen.meta.mainProgram == "fen";
assert fen.meta.license == pkgs.lib.licenses.mit;
assert builtins.elem system fen.meta.platforms;
pkgs.runCommand "fen-downstream-check" {
  nativeBuildInputs = [ fen ];
} ''
  fen --help > "$out"
  fen --version >> "$out"
''
