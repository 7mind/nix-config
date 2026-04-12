{ lib, rustPlatform, mqtt-controller-frontend ? null }:

# Builds the mqtt-controller workspace. The workspace contains three
# crates:
#
#   * mqtt-controller          — the binary (provision + daemon subcommands)
#   * mqtt-controller-wire     — shared WebSocket API wire types
#   * mqtt-controller-frontend — Leptos CSR frontend (built separately for WASM)
#
# This derivation builds only the native binary. The WASM frontend is
# built by a separate derivation (see frontend.nix).
#
# We use `cargoLock.lockFile` rather than a vendored `cargoHash` so the
# build is reproducible from `Cargo.lock` alone — no need to update a
# hash by hand on every dep bump.

rustPlatform.buildRustPackage {
  pname = "mqtt-controller";
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

  # Only build the server binary, not the frontend WASM crate.
  cargoBuildFlags = [ "-p" "mqtt-controller" ];
  cargoTestFlags = [ "-p" "mqtt-controller" "-p" "mqtt-controller-wire" ];

  # Run `cargo test` during the build. The crate's tests are pure Rust
  # (no MQTT broker, no network) so this is fast and the build refuses
  # to install a binary that fails its own tests.
  doCheck = true;

  postInstall = lib.optionalString (mqtt-controller-frontend != null) ''
    mkdir -p $out/share/mqtt-controller
    cp -r ${mqtt-controller-frontend} $out/share/mqtt-controller/web
  '';

  passthru = {
    inherit mqtt-controller-frontend;
  };

  meta = with lib; {
    description = "Unified zigbee2mqtt provisioner and runtime controller";
    license = licenses.mit;
    maintainers = with maintainers; [ pshirshov ];
    mainProgram = "mqtt-controller";
    platforms = platforms.linux;
  };
}
