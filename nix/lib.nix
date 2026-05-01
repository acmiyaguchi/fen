{ lib }:

{
  artifactSystemFor = targetSystem:
    if targetSystem == "x86_64-linux" then "linux-x86_64"
    else if targetSystem == "aarch64-linux" then "linux-aarch64"
    else if targetSystem == "armv7l-linux" then "linux-armv7-gnueabihf"
    else targetSystem;

  dockerArchitectureFor = targetSystem:
    if targetSystem == "x86_64-linux" then "amd64"
    else if targetSystem == "aarch64-linux" then "arm64"
    else if targetSystem == "armv7l-linux" then "arm"
    else null;

  qemuFor = targetSystem:
    if targetSystem == "aarch64-linux" then "qemu-aarch64"
    else if targetSystem == "armv7l-linux" then "qemu-arm"
    else null;

  dynamicLinkerFor = targetSystem:
    if targetSystem == "x86_64-linux" then "/lib64/ld-linux-x86-64.so.2"
    else if targetSystem == "aarch64-linux" then "/lib/ld-linux-aarch64.so.1"
    else if targetSystem == "armv7l-linux" then "/lib/ld-linux-armhf.so.3"
    else null;
}
