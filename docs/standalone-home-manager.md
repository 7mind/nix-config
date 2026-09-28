# Standalone Home Manager on Ubuntu

The `pavel@ubuntu-x86_64` configuration applies Pavel's CLI and development
settings without managing the operating system. It targets an x86_64 Ubuntu
machine with a `pavel` account whose home directory is `/home/pavel`. It uses
the public configuration; private host modules and secrets are not loaded.

Install Nix with flakes enabled, then clone this repository as `pavel`. From
the repository root, run:

```sh
nix run '.?submodules=0#home-manager-cli' -- switch -b hmbak --flake '.?submodules=0#pavel@ubuntu-x86_64'
```

The CLI comes from this flake's pinned Home Manager input. `-b hmbak` backs up
existing files that would otherwise conflict with activation. Subsequent
switches use the same command. Home Manager manages the user's dotfiles and
packages; Ubuntu continues to manage system services and the login shell.
