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
existing files that would otherwise conflict with activation. Home Manager
manages the user's dotfiles and packages; Ubuntu continues to manage system
services and the login shell.

## Switching from any working directory

The repository-root `switch-hm` helper selects a configuration through the
flake's `homeConfigurations` output. It does not source configuration files.
Run it using the path to your checkout:

```sh
/path/to/nix-config/switch-hm --list          # Available user@host-arch configurations
/path/to/nix-config/switch-hm                 # Current hostname and user
/path/to/nix-config/switch-hm ubuntu          # Explicit hostname
/path/to/nix-config/switch-hm ubuntu --user pavel --no-push
/path/to/nix-config/switch-hm --no-git -- --show-trace
```

Like `setup`, the helper automatically re-enters this checkout's pinned
`nix develop` shell before switching. Invoking it from a parent directory does
not require direnv to have loaded `.envrc`. A stale shell missing rekey tools is
refreshed once; a still-incomplete shell fails explicitly rather than looping.
`--help`, `--list`, and invalid arguments do not bootstrap or stage files.

The default selector is `USER@HOST-ARCH`, using `id -un`, `hostname -s`, and
`uname -m`. On macOS the architecture suffix includes `-darwin`, with `arm64`
normalized to `aarch64`. Without `--target-host`, the hostname selects a profile
to activate **locally**; the helper does not change the invoking user. The selected
configuration must already be declared in the flake.

`-l` / `--list` prints all `homeConfigurations` keys in sorted order, including
other users, architectures, and macOS profiles. It does not activate a profile,
modify the flake lock, or stage, commit, or push Git changes. As with other Git
flake evaluations, new files must already be staged for Nix to see them.

When switching, like `setup`, it stages changes in the checkout and initialized
submodules so Nix can see new files. After a successful switch it commits changes and pushes
with `--recurse-submodules=on-demand`. Generated commit messages are simply
`autosave`, without hostname, username, or configuration names. A failed switch
leaves staged changes but does not commit or push. It does not fetch or rebase.

- `-n` / `--no-git`: skip commits and pushes (staging still happens).
- `-np` / `--no-push`: commit locally only.
- `-m` / `--message`: use a custom message verbatim; avoid sensitive names.
- `--rekey`: rekey only the selected profile locally before activation; disabled
  by default. See the master-identity requirements below.
- `--`: pass remaining arguments to Home Manager locally, or both `nix eval`
  and `nix build` remotely (options must be accepted by both). With `--rekey`,
  they must also be accepted by `nix eval`, `nix run`, and `nix develop`.
  Rekey shell bootstrap receives the same input overrides.

The helper uses the pinned CLI and `hmbak` backups from the command above, with
submodules enabled when present. Use the explicit `?submodules=0` command above
when you need to exclude submodules.

## Optional profile-scoped rekey

On a trusted Linux machine with existing TPM enrollment, one command unlocks,
rekeys, and switches. Enroll the existing master-key backup once with
`./enroll-tpm "$HOME/age-key.age"`; `./enroll-tpm --verify` checks enrollment.
Enrollment is not repeated during switches.


```sh
./switch-hm laptop --user alice --rekey --no-git
# If portable changes are not yet pinned:
./switch-hm laptop --user alice --rekey --no-git -- \
  --override-input ponygirls git+file:///absolute/path/to/ponygirls
```

The first command activates locally; use it only on the intended switching
machine. For a remote target, use `--target-host` as described below. Keep master
identities on the trusted rekeying machine, never copy them to deployment targets.
Readable configured master identities are reused and left intact. If the Linux
runtime identity `/dev/shm/age-master-key` is absent, `--rekey` unlocks it with
`$HOME/.age/tpm-identity.txt` and `$HOME/.age/master-key.age`. Missing enrollment,
TPM access failures, and decryption failures abort deployment; there is no
password-backup fallback or automatic enrollment.

The newly unlocked key is mode `0600`, published without replacing an existing
file, and removed immediately after rekey, including on failure or catchable
termination. Pre-existing keys are untouched, and publishing a new key never
overwrites another file. Linux switches lock the runtime path; a concurrent switch
fails explicitly rather than reusing a temporary key another switch may remove.
Do not manually replace that path while rekey is running. SIGKILL cannot run
cleanup. Other configured identity paths must be unlocked explicitly. `AGE_RUNTIME_KEY` can
select the eligible runtime path, but must match the profile's configured
identity and remain outside the checkout. `AGE_TPM_IDENTITY` and
`AGE_MASTER_KEY_TPM` override the local enrollment paths. These environment
variables do not modify the Nix profile. Normal switches do not unlock keys.

Rekey uses the selected profile's pinned agenix-rekey input and accepts only
local storage under `private/secrets/rekeyed/<profile-directory>`. It stages source
before evaluation and the selected directory's generated ciphertext before
building/activating. Input overrides are applied to metadata evaluation, rekey,
and activation. Stage new files in any sibling Git-flake input separately.
Missing identities or rekey failures abort deployment without committing/pushing;
rekey is noninteractive and never selects retry or dummy values. Existing staged
source and any successfully generated ciphertext remain available for inspection.
`--rekey` cannot be combined with `--list`.

## Switching a remote host

Run from your local checkout; the target needs installed Nix and an existing
SSH login, but no repository checkout or Home Manager CLI:

```sh
./switch-hm --target-host alice@server --dry-run
./switch-hm --target-host alice@server --no-git
./switch-hm --target-host alice@server declared-profile --no-push
```

Remote mode discovers the target's login user, short hostname, architecture,
platform and home directory. If Nix is absent from the non-login SSH PATH, the
helper explicitly reports using the user's or daemon's standard Nix profile.
An explicit hostname selects a different declared
profile; it does not change the SSH destination. The selected profile's username
and home directory must match the remote login, otherwise deployment stops.

The helper builds locally, transfers only the activation closure with `nix copy`,
and activates as the SSH user using `hmbak` backups. It does not synchronize the
checkout or provision authentication. Files referenced by the selected profile
are part of its closure; choose the appropriate profile for the target. Existing
source snapshots on the target are unchanged. Cross-platform builds require cached outputs or a
configured builder for the target platform; pass common Nix evaluation/build
options such as `--builders`, `--offline` or `--show-trace` after `--`. Evaluation
overrides apply to both identity validation and the activation build. Build-only
flags such as `--rebuild` are not supported through this interface.

If the target's daemon rejects unsigned local outputs, explicitly add
`--use-remote-sudo`. This uses passwordless `sudo -n` only for the store import,
never for Home Manager activation. SSH aliases, ports and identity files come
from SSH config; `NIX_SSHOPTS` supplies additional single-line, space/tab-separated
SSH arguments for both probing/activation and closure transfer. Shell quoting is
not interpreted; use SSH config for options or paths containing spaces. Line
breaks are rejected before connecting to prevent inconsistent transport options.

With `--rekey`, remote identity validation runs first, then only the selected
profile is rekeyed locally before the activation build. The master identity is
not copied. TPM unlocking, if needed, also happens only on the local machine.
`--dry-run` skips rekey entirely, including TPM unlocking and master-identity checks.

`--dry-run` evaluates the profile and previews its build without copying,
activating, committing or pushing. Source files are still staged for Nix.
Failures in probing, evaluation, build, transfer or activation prevent commits
and pushes. The existing Git switches apply to successful remote deployments.
