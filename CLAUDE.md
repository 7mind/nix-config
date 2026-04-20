# NixOS Configuration

## Building and Testing

When you've added a new feature or performed a refactoring, run verification build for the current host:

```bash
# Build all hosts
./verify-configs --verbose $HOSTNAME
```

When changing shared modules, check all hosts:

```bash
# Build all hosts
./verify-configs --verbose
```

When verifying new features, run the same steps as CI:
  1. Check whether hosts build without private modules:
    ```bash
    # Build all public hosts without private modules
    ./verify-configs --verbose --no-submodules
    ```
  2. Run `nix flake check --no-build '.?submodules=0'`

Prefer using `./verify-configs`/`nix build --dry-run` over `nix build` for verification to avoid slow building of packages.
When changing Home Manager activations a full nix build may still be required as those require executing activations themselves to verify their correctness.

This repository uses git submodules. Always use `?submodules=1` when building or using `nix eval` (unless verifying CI steps):

```bash
# Build a specific host configuration
nix build ".?submodules=1#nixosConfigurations.HOSTNAME.config.system.build.toplevel"

# Examples:
nix build ".?submodules=1#nixosConfigurations.pavel-fw.config.system.build.toplevel"
nix build ".?submodules=1#nixosConfigurations.pavel-am5.config.system.build.toplevel"

# For Darwin (macOS):
nix build ".?submodules=1#darwinConfigurations.HOSTNAME.system"
```

Use `./setup` script for full build + switch workflow:
- `./setup` - build current host
- `./setup -s` - build and switch
- `./setup -r` - update flake inputs before building
- `./setup -ng` - skip git commit/push

## Structure

- `/hosts/` - Per-host configurations
- `/modules/nixos/` - NixOS modules
- `/modules/darwin/` - macOS modules
- `/modules/hm/` - Home-manager modules
- `/roles/` - High-level role definitions
- `/private/` - Secrets and private configs (submodule)
