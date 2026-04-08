{ lib, rustPlatform }:

# Builds the hue-controller crate via the standard nixpkgs Rust
# infrastructure. The crate is a single binary with two subcommands —
# `provision` (replaces hue-setup) and `daemon` (replaces the bento
# mqtt-automation service). Both subcommands link to the same library
# code and share the same JSON config schema.
#
# We use `cargoLock.lockFile` rather than a vendored `cargoHash` so the
# build is reproducible from `Cargo.lock` alone — no need to update a
# hash by hand on every dep bump.

rustPlatform.buildRustPackage {
  pname = "hue-controller";
  version = "0.1.0";

  src = lib.cleanSourceWith {
    src = ./.;
    filter = name: type:
      let baseName = baseNameOf (toString name); in
      ! (
        # Skip the build artifacts directory if a developer ran cargo
        # locally before invoking nix build.
        (type == "directory" && baseName == "target")
      );
  };

  cargoLock = {
    lockFile = ./Cargo.lock;
  };

  # Run `cargo test` during the build. The crate's tests are pure Rust
  # (no MQTT broker, no network) so this is fast and the build refuses
  # to install a binary that fails its own tests.
  doCheck = true;

  meta = with lib; {
    description = "Unified zigbee2mqtt provisioner and runtime controller for Hue lights";
    license = licenses.mit;
    maintainers = with maintainers; [ pshirshov ];
    mainProgram = "hue-controller";
    platforms = platforms.linux;
  };
}
