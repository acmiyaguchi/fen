# Apalache, the symbolic model checker behind `quint verify` (make check-spec).
# Not in nixpkgs; this is the upstream release `quint verify` would otherwise
# download into ~/.quint on first use. Keep `version` equal to quint's
# `--apalache-version` default, or quint warns about an incompatible server.
# Dev shell only: never part of a shipped artifact.
{ lib, stdenvNoCC, fetchurl, makeWrapper, bash, jre_headless, stdenv }:

stdenvNoCC.mkDerivation rec {
  pname = "apalache";
  version = "0.56.1";

  src = fetchurl {
    url = "https://github.com/apalache-mc/apalache/releases/download/v${version}/apalache-${version}.tgz";
    # Matches the release's sha256sum.txt.
    sha256 = "a61c07569d7195ddc589f01037fa10fafef4fb0796af2f1c9cb45226375dfbfc";
  };

  nativeBuildInputs = [ makeWrapper ];
  buildInputs = [ bash ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib $out/libexec
    cp lib/apalache.jar $out/lib/
    cp bin/apalache-mc $out/libexec/apalache-mc
    patchShebangs $out/libexec/apalache-mc
    # The launcher finds the jar relative to itself; point it at $out/lib.
    # Z3 ships inside the jar as a JNI library that needs libstdc++.
    makeWrapper $out/libexec/apalache-mc $out/bin/apalache-mc \
      --set APALACHE_JAR $out/lib/apalache.jar \
      --prefix PATH : ${lib.makeBinPath [ jre_headless ]} \
      --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ stdenv.cc.cc.lib ]}
    runHook postInstall
  '';

  meta = {
    description = "Symbolic model checker for TLA+ and Quint";
    homepage = "https://apalache-mc.org";
    license = lib.licenses.asl20;
    platforms = lib.platforms.unix;
  };
}
