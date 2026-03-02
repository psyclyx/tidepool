{
  lib,
  stdenv,
  bison,
  callPackage,
  expat,
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

  src = ./.;

  deps = callPackage ./build.zig.zon.nix {};

  nativeBuildInputs = [
    bison
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

  meta = {
    description = "Janet-based window manager for River";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "tidepool";
  };
})
