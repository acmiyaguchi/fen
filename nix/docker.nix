{ targetPkgs, version, artifactSystem, dockerArchitecture, distTree }:

targetPkgs.dockerTools.buildImage {
  name = "fen-dist-scratch-test";
  tag = version;
  architecture = dockerArchitecture;
  copyToRoot = targetPkgs.runCommand "fen-${version}-${artifactSystem}-scratch-root" {} ''
    mkdir -p "$out/bin" "$out/etc/ssl/certs" "$out/tmp"
    chmod 1777 "$out/tmp"
    cp -a ${distTree}/opt "$out/opt"
    cp -L ${targetPkgs.pkgsStatic.busybox}/bin/busybox "$out/bin/busybox"
    ${targetPkgs.pkgsStatic.busybox}/bin/busybox --list | while IFS= read -r applet; do
      ln -sf busybox "$out/bin/$applet"
    done
    cp ${targetPkgs.cacert}/etc/ssl/certs/ca-bundle.crt \
      "$out/etc/ssl/certs/ca-bundle.crt"
  '';
  config = {
    Env = [
      "PATH=/bin"
      "TMPDIR=/tmp"
      "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
      "CURL_CA_BUNDLE=/etc/ssl/certs/ca-bundle.crt"
    ];
    Entrypoint = [ "/opt/fen/bin/fen" ];
  };
}
