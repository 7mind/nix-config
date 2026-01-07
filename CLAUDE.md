# NixOS Configuration

## Core principles

- You run in a sandbox and cannot read files in $HOME nor interact with system. You can only observe the project and files in /nix. 
- When you need to interact with the system, prepare a script writing output into temporary file in /tmp, ask user to run it, then read output

## Building and Testing

This repository uses git submodules. Always use `?submodules=1` when building:

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
