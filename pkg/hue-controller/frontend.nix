# The hue-frontend WASM bundle is built via crane in the nixpkgs
# overlay (modules/nixos/overlay.nix) rather than as a standalone
# derivation, because crane needs a Rust toolchain with the
# wasm32-unknown-unknown target provided by rust-overlay.
#
# See overlay.nix for the actual build definition using
# craneLib.buildTrunkPackage.
#
# For local development without Nix:
#   cd crates/hue-frontend
#   trunk serve  # (requires rustup target add wasm32-unknown-unknown)
throw "hue-frontend is built via crane in overlay.nix, not as a standalone derivation"
