{
  lib,
  stdenv,
  bison,
  callPackage,
  expat,
  installShellFiles,
  libffi,
  libxml2,
  libxkbcommon,
  pkg-config,
  wayland,
  zig_0_15,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "tidepool";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.fileFilter (f: (f.hasExt "janet" || f.hasExt "zig" || f.hasExt "zon" || f.hasExt "xml")) ./.;
  };

  deps = callPackage ./build.zig.zon.nix {};

  nativeBuildInputs = [
    bison
    installShellFiles
    pkg-config
    zig_0_15
  ];

  buildInputs = [
    expat
    libffi
    libxml2
    libxkbcommon
    wayland
  ];

  zigBuildFlags = [
    "--system"
    "${finalAttrs.deps}"
  ];

  postInstall = ''
    installShellCompletion --cmd tidepoolmsg \
      --bash <($out/bin/tidepoolmsg completions bash) \
      --zsh <($out/bin/tidepoolmsg completions zsh) \
      --fish <($out/bin/tidepoolmsg completions fish)
  '';

  meta = {
    description = "Janet-based window manager for River";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "tidepool";
  };
})
