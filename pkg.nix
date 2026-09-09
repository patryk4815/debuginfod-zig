{
  lib,
  stdenv,
  fetchFromGitHub,
  pkgsBuildHost,
  targetPackages,

  # Others
  flags ? [ ],
}:
let
  isCross = stdenv.buildPlatform.system != stdenv.targetPlatform.system;
  isSameOS = stdenv.buildPlatform.parsed.kernel.name == stdenv.targetPlatform.parsed.kernel.name;
  glibcVersion = if stdenv.targetPlatform.isLoongArch64 then ".2.36" else ".2.28";
  muslVersion = if stdenv.targetPlatform.isLoongArch64 then "" else "";
  abiVersion =
    if stdenv.targetPlatform.isGnu then
      glibcVersion
    else if stdenv.targetPlatform.isMusl then
      muslVersion
    else
      (throw "not supported abi version ${stdenv.targetPlatform.parsed.abi.name}");

  zigTarget =
    if stdenv.targetPlatform.isLinux && stdenv.targetPlatform.is32bit then
      "-Dtarget=${stdenv.targetPlatform.parsed.cpu.family}-linux-${stdenv.targetPlatform.parsed.abi.name}${abiVersion}"
    else if stdenv.targetPlatform.isLinux then
      "-Dtarget=${stdenv.targetPlatform.parsed.cpu.name}-linux-${stdenv.targetPlatform.parsed.abi.name}${abiVersion}"
    else if stdenv.targetPlatform.isDarwin then
      "-Dtarget=${stdenv.targetPlatform.parsed.cpu.name}-macos.${stdenv.targetPlatform.darwinSdkVersion}"
    else
      (throw "not supported target");
in
stdenv.mkDerivation {
  name = "debuginfod-zig";
  version = "0.194";

  src = ./.;

  preBuild = ''
    export ZIG_GLOBAL_CACHE_DIR=$TMPDIR
  '';

  zigBuildFlags = [
    zigTarget
  ]
  ++ flags;

  postInstall =
    let
      ld =
        if stdenv.targetPlatform.isLinux then
          "$(echo ${targetPackages.stdenv.cc.bintools.dynamicLinker})"
        else
          "";
      qemu =
        if stdenv.targetPlatform.isLinux && isCross then
          "${pkgsBuildHost.qemu-user}/bin/qemu-${stdenv.targetPlatform.qemuArch}"
        else
          "";
    in
    lib.optionalString isSameOS ''
      echo "Starting tests..."
      ${qemu} ${ld} $out/bin/test
      ${qemu} ${ld} $out/bin/test-find
      ${qemu} ${ld} $out/bin/debuginfod-find --version
    '';

  # Allow tests that bind or connect to localhost on macOS.
  __darwinAllowLocalNetworking = true;

  nativeBuildInputs = [
    pkgsBuildHost.dev_zig_0_17.hook
  ];
}
