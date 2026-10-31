# JabraCLI

Official proprietary JabraCLI, packaged from the Linux x86-64 AppImage.
The extracted application, bundled .NET runtime, and firmware updater run in
an FHS environment without requiring FUSE. Other platforms are not packaged.

From the flake root:

```bash
nix run .#jabracli -- --help
nix run .#jabracli -- device list
```

The flake's package set explicitly permits only JabraCLI's unfree license,
so its package output and pure flake checks need no environment opt-in.
The shared overlay also exposes `pkgs.jabracli` for NixOS/Home Manager packages.
Enable unfree packages (or allow `jabracli` with `allowUnfreePredicate`) in the
consuming configuration. The NixOS and Home Manager Linux desktop defaults
include it on x86-64. This package does not install device permission rules.
Device access requires appropriate USB/hidraw
permissions; consult Jabra's documentation before running privileged commands.
Run from a writable working directory for configuration and firmware downloads.

Upstream documents anonymous usage/error telemetry. See the
[upstream README](https://file.cloud.jabra.com/cli-tool/README.md) and
[license agreement](https://developer.jabra.com/legal/license-agreement).
The package is marked `unfree`, not redistributable `unfreeRedistributable`.

## Verification

```bash
nix build .#jabracli
# Disable networking during smoke tests, including any upstream telemetry.
bwrap --unshare-net --dev-bind / / ./result/bin/jabracli --version
bwrap --unshare-net --dev-bind / / ./result/bin/jabracli --help
bwrap --unshare-net --dev-bind / / ./result/bin/jabracli device list --output-format json
env -u NIXPKGS_ALLOW_UNFREE nix --option accept-flake-config false \
  --option allow-import-from-derivation false flake check --no-write-lock-file --no-build .
```

Version 1.6.48.0 built and passed these smoke checks; device enumeration returned
success with an empty list. Real-device operations and firmware updates have not
been tested. The firmware updater's documented `/usr/lib/7zip/7za` path is
provided using nixpkgs' current 7-Zip, not legacy p7zip.
