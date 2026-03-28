{
  lib,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
  libinput,
}:

rustPlatform.buildRustPackage {
  pname = "linux-3-finger-drag";
  version = "1.6.0-unstable-2025-11-24";

  src = fetchFromGitHub {
    owner = "lmr97";
    repo = "linux-3-finger-drag";
    rev = "d95fbb48d8c9e8d3b659c613525bd3285e11fc7f";
    hash = "sha256-sLy8twEKiSZZAiTnD6Zeh+g5wmEq4FqvGNTPmY8eRqU=";
  };

  cargoHash = "sha256-oJESYBV26acyknIDcGnxDhBOBsXoqgy9OEHIhKf9uZQ=";

  nativeBuildInputs = [ pkg-config ];

  buildInputs = [ libinput ];

  meta = {
    description = "Three-finger trackpad dragging for Linux (like macOS)";
    homepage = "https://github.com/lmr97/linux-3-finger-drag";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "linux-3-finger-drag";
  };
}
