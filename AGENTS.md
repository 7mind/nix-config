# NixOS Configuration

## Building and Testing

After a trivial change concerning exactly one host, verifying just that host is enough (substitute the hostname reported by the SessionStart hook — `$HOSTNAME` is bash-only and is empty under zsh, the user's login shell):

```bash
# Build the current host (replace HOSTNAME with the actual short hostname, e.g. testbench)
nix build --dry-run ".#nixosConfigurations.HOSTNAME.config.system.build.toplevel"
```

After significant changes that may affect many hosts (for example shared modules, roles, overlays, package definitions, or refactorings), check every configuration this flake exports with `nix flake check --no-build '.'`.

When verifying new features, run the same steps as CI:
  1. Run `nix flake check --no-build '.'`

Prefer using `nix build --dry-run` over `nix build` for verification to avoid slow building of packages.
When changing Home Manager activations a full nix build may still be required as those require executing activations themselves to verify their correctness.

This flake works independently. Downstream configuration repositories consume `lib.mkFlake` and use their own checkout as the flake root:

```bash
# Build a specific host configuration
nix build ".#nixosConfigurations.HOSTNAME.config.system.build.toplevel"

# Example:
nix build ".#nixosConfigurations.testbench.config.system.build.toplevel"

# For Darwin (macOS):
nix build ".#darwinConfigurations.HOSTNAME.system"
```

## Structure

- `/hosts/` - Per-host configurations
- `/modules/nixos/` - NixOS modules
- `/modules/darwin/` - macOS modules
- `/modules/hm/` - Home-manager modules
- `/roles/` - High-level role definitions
- `/lib/mk-flake.nix` - Shared output composition for downstream flakes
