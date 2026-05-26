{ targetPkgs, version, artifactSystem, dockerArchitecture, fenBinary }:

targetPkgs.dockerTools.buildImage {
  name = "fen-scratch-test";
  tag = version;
  architecture = dockerArchitecture;
  copyToRoot = targetPkgs.runCommand "fen-${version}-${artifactSystem}-scratch-root" {} ''
    mkdir -p "$out/bin" "$out/etc/ssl/certs" "$out/tmp"
    chmod 1777 "$out/tmp"

    install -Dm755 ${fenBinary}/bin/fen "$out/bin/fen"

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
      "HOME=/tmp"
      "TMPDIR=/tmp"
      "XDG_STATE_HOME=/tmp/state"
      "XDG_CONFIG_HOME=/tmp/config"
      "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
      "CURL_CA_BUNDLE=/etc/ssl/certs/ca-bundle.crt"
    ];
    Entrypoint = [ "/bin/fen" ];
  };
}
