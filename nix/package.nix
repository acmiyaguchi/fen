# Reusable static runtime; uses the caller's package set, not flake inputs.
{ pkgs
, version ? "v${pkgs.lib.fileContents ../VERSION}"
, versionInfo ? {
    inherit version;
    gitRev = "";
    gitShortRev = "";
    dirty = false;
    source = "nix";
    lastModified = "";
    buildSystem = pkgs.stdenv.buildPlatform.system;
  }
}:
let
  targetSystem = pkgs.stdenv.hostPlatform.system;
  supported = [ "x86_64-linux" "aarch64-linux" "armv7l-linux" ];
  artifacts = import ./artifacts.nix ({
    inherit pkgs version versionInfo targetSystem;
    targetPkgs = pkgs.pkgsStatic;
  } // import ./lib.nix { inherit (pkgs) lib; });
in
assert pkgs.lib.assertMsg (builtins.elem targetSystem supported)
  "fen supports x86_64-linux, aarch64-linux, and armv7l-linux only";
artifacts.fenBinary
