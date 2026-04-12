# The mqtt-controller native binary is built via crane in the nixpkgs
# overlay (modules/nixos/overlay.nix) to separate dependency compilation
# from source compilation — deps are cached and only rebuilt when
# Cargo.lock changes.
#
# For local development without Nix:
#   cargo build -p mqtt-controller
throw "mqtt-controller is built via crane in overlay.nix, not as a standalone derivation"
