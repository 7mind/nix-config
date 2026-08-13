{
  lib,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
  libinput,
}:

rustPlatform.buildRustPackage {
  pname = "linux-3-finger-drag";
  version = "1.7.0";

  src = fetchFromGitHub {
    owner = "lmr97";
    repo = "linux-3-finger-drag";
    rev = "d917e2393aff4e9994c5f8519e6157518bbb12fb";
    hash = "sha256-wsM4qPAk/H5HK848Fky+Vc3qvrImJ4HikYYsS18equQ=";
  };

  cargoHash = "sha256-bHiVZfI3g9pjOdRfVCoI4+96wZPFCYrq17rrPc34e0s=";

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
