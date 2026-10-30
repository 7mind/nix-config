# flurry

A little swarm of flakes. Maintain a directory of related Nix/Git repositories
without publishing your half-written work by accident.

The authoritative source is `nix-config/pkg/flurry`. Flurry is included in
nix-config's default NixOS, nix-darwin and Home Manager package lists; existing
sane-default opt-outs still apply. These declarative defaults take effect when
you next activate your configuration. It is exported as `packages.<system>.flurry`:

```bash
# From nix-config; no host activation required:
nix run .#flurry -- --help
nix build .#flurry
```

Python 3.11+, Git with `check-attr --source` support and Nix with flakes support
are required. GitHub permission queries use `gh`; GitLab queries use `glab`,
authenticated separately for the appropriate host. No Python runtime dependencies.
From the source directory (`pkg/flurry`):

```bash
./bin/flurry --help                 # run directly from this directory
python3 -m flurry --help            # or use the module
python3 -m pip install .            # optional installation; provides flurry
```

A Nix `package.nix` is provided for `pkgs.callPackage ./package.nix { }`.

## Workspace maintenance

Run in the directory containing your flakes, not inside the tool checkout:

```bash
flurry status
flurry graph
flurry plan --preserve
flurry sync                        # require clean source checkouts
flurry sync --preserve              # keep existing edits local
flurry sync --commit staged --message 'Finish the selected work'
flurry sync --commit all --message 'Finish this change'
flurry sync --preserve --exclude 'scratch-*'
```

`--without-committing` is an alias for `--preserve`. **Generated lock changes are
still committed and pushed in preserve mode.** A nontrivial rebase also replaces
commit IDs. `--commit all` includes Git-visible untracked files, so review the
`plan`/`status` output first. It never includes ignored files.

For A → B → C, Flurry rehearses all Git rebases/restorations first, then publishes
A, updates/checks/commits B's lock and publishes B, then does the same for C.
Consumers' resulting lock revisions must equal the actual prepared/published
provider commits. Fixed-revision inputs are boundaries, not requests to rewrite
`flake.nix`. Unrelated external dependencies are not deliberately upgraded;
transitive lock nodes can change when a provider changes its own dependencies.

`plan` and `sync --dry-run` enforce the same local dirty-state policy as `sync`:
known blockers fail with a nonzero exit before a run journal is created. This
includes retained staged, unstaged or visible untracked root flake-file edits.
Plans remain local and provisional: no fetch, commit or push. `status`/`graph`
also do not fetch. Remote races, authentication, rebase/restore rehearsals and
later Nix validation can still fail. Use `--json` for structured output and `--root DIR`
to select a workspace explicitly. Global flags may appear before or after the
command. Every subprocess has a configurable `--timeout` (seconds).

Human command output is coloured by default on terminals: repository names and
progress in cyan, clean/success states in green, warnings/dirty changes in yellow,
and errors in red. Redirected output and `--json` stay plain. A nonempty
`NO_COLOR` or `TERM=dumb` disables automatic colouring. Use `--color=always` to
force colour, `--color=never` to disable it, or `--color=auto` for the default;
explicit controls override the environment, but `--json` always stays uncoloured.

Validation defaults to `--check eval` (`nix flake check --no-build`, no lock
writes). `--check full` additionally builds checks; `--check none` explicitly
skips validation and emits a warning. Flurry never activates or deploys anything.

## Configuration

Configuration is optional. `flurry init` creates `flurry.toml` in the workspace
root without Git, Nix or network access. Defaults exclude nothing and set no
explicit GitLab hosts. Existing files, directories and symlinks are never
overwritten; no checkouts or recovery state are created.

```bash
flurry init --root /path/to/workspace
# Explicitly persist exclusions when initializing another workspace:
flurry init --root /another/workspace --exclude 'wt-*'
```

Example `flurry.toml`:

```toml
version = 1
exclude = ["wt-*", "scratch-*"]
gitlab_hosts = ["gitlab.example.com"]

[repositories.application]
path = "application"
source = "github:example/application"
rebase_onto = "origin/main"
push_remote = "origin"
push_ref = "refs/heads/main"
```

`flurry.local.toml` overlays repository fields for machine-local settings.
Exclusions from both files and repeated `--exclude` flags are additive. Unknown
keys and invalid paths are errors. Exclusion patterns that match no repository
are harmless no-ops, so patterns can cover checkouts that are not currently present.
Paths must remain inside the workspace. Do not put credentials in configuration.

Normally Flurry discovers immediate sibling Git flakes and initialized submodules,
plus local non-flake Git repositories referenced as source inputs. Explicit
repository entries can include other workspace-relative checkouts. It deduplicates
physical aliases, not independent linked worktrees. Ambiguous provider worktrees
require a branch selection or exclusion; merely finding a topic worktree does not
make its HEAD the correct version for an input tracking `main`.

Rebase targets default to each branch's upstream. Push destinations default to the
current branch on its configured push remote/upstream remote. Explicit overrides
are shown in the plan. Pushing a topic branch does not update a `main` input;
branch/ref mismatches and non-fast-forward publication are refused. Separate
fetch/push repository identities are not guessed into equivalence.

An excluded worktree's branch, index and files are not changed. Included linked
worktrees share Git storage, so their fetches can change shared remote-tracking
refs. If no included provider remains, the excluded repository is a frozen lock
boundary, including transitive lock nodes; an incompatible update fails explicitly.

## Pull writable dependencies

```bash
flurry pull application --dry-run
flurry pull application
flurry pull github:example/application
```

Here `pull` means **bootstrap sibling checkouts**, not `git pull`. Existing roots
or configured aliases can use short names; otherwise supply an explicit flake
reference. Dependencies are materialized under the invocation's workspace/current
directory. The input graph is discovered from Nix lock metadata, including paths
through read-only or excluded repositories. Only repositories with authenticated,
affirmative code-write permission are cloned. No forks or remote branches are
created, and no trial pushes are used to test permission.

New clones check out branch tips, not historical lock revisions. Existing matching
checkouts are reused without fetch, branch switching or file changes. The discovered
closure belongs to the root's lock graph: it is not a claim that every different
new branch tip has the same dependencies. The plan reports locked revisions,
chosen branches, provenance, permissions, destinations, skips and blockers.

GitHub.com and explicitly configured GitLab hosts use authenticated APIs.
A flake URL cannot authorize sending API credentials to an arbitrary host. Permission evidence refers
to the reported API principal, not proof that a different SSH key/token can push.
Branch protection may still prevent later publication. Archived/disabled repositories
are not writable; unsupported hosts, missing authentication, API failures and
unknown/custom permissions are blockers rather than authorization. GitLab hosts
other than `gitlab.com` must be listed in `gitlab_hosts`; authenticate using
`glab auth login --hostname HOST`. GitHub uses `gh auth login`.

Clone names default to repository basenames. Configure `source` plus `path` to
resolve basename collisions. Existing mismatched directories and symlinks are
never overwritten. Clones are prepared in private temporary siblings and published
with no-clobber rename (Linux and macOS); recursive submodule cloning is disabled.
No-overwrite publication on macOS is implemented but must be validated there;
the Linux path is exercised by the local Git fixtures. Pull also requires an
exclusively used, trusted workspace: path checks do not provide race-proof
confinement against a concurrent writer replacing ancestor directories.

## Safety and recovery

**Run exclusively:** do not edit selected repositories or run other Git operations
while synchronization is executing. Workspace locks coordinate Flurry instances,
not editors, hooks or other tools. Fingerprint checks narrow races; they are not a
filesystem transaction.

Preservation follows Git's content/executable-bit model, including staged versus
unstaged changes, visible untracked files and old stashes—not arbitrary Unix
metadata, ignored file snapshots, ownership, ACLs or timestamps. Preservation
checks and dirty restore are rehearsed in isolated local clones. Required Git
identity/signing settings are retained. Internal checkout/stash/rebase hooks are
disabled; ordinary push hooks run in the source repository. Intentional user and
generated-lock commits run native Git commit hooks from the source's resolved
hooks directory, including local/global/conditional `core.hooksPath` settings.
Hooks run with the **trial checkout and candidate index**, not the dirty source.
Source-side hook scripts and their adjacent helpers remain available; source-only
ignored tools and arbitrary repository-local configuration are not copied.
Hooks must support that isolated context; failures stop the operation without
publishing that candidate. There is no commit-hook bypass, even with `--check none`.

Hooks may validate or edit the commit message, but changing the planned tree,
remaining Git-visible working contents, branch, index or configuration is refused.
Hook-staged extras and formatter rewrites are not silently accepted. Failed trials
are retained for inspection. Hooks are trusted executable code: Flurry does not
sandbox their external side effects, and already-published providers are not
rolled back if a consumer hook rejects its commit.

Initial explicit restrictions:

- Gitlink-bearing parent repositories cannot be synchronized yet. Discovery can
  report them; standalone child worktrees do not grant permission to rewrite pins.
- Effective Git clean/smudge filter attributes, nontrivial `core.autocrlf`,
  source-only attributes, sparse checkout, special index flags, intent-to-add and
  ongoing Git operations are refused where preservation cannot be established
  safely. Unused registered drivers, including global Git LFS, are allowed.
- Preserve mode refuses pre-existing `flake.nix`/`flake.lock` edits that overlap
  generated lock work. Commit/reconcile those files explicitly first.
  `--commit staged` also refuses unstaged or untracked flake edits left outside
  that scope; `--commit all` includes them only when explicitly requested.
- Same-repository and subdirectory-flake publication arrangements are reported
  unsupported instead of assuming a valid ordering. Registry-only input identifiers
  need explicit Git references.

Filter checks cover HEAD/index/worktree views, incoming files, generated locks
and sentinels, and temporary-index capture/checkout contexts. Source/trial global
attribute-file paths must match. Uncaptured/ignored `.gitattributes` affecting
original or incoming paths are refused. Preserved `.gitattributes` changes combined with
incoming attribute-file changes are conservatively refused, even in different
directories or when staged and unstaged changes cancel. Reserved driver names
`unset` and `unspecified` are refused when attribute output is ambiguous.

There is **no atomic transaction across remote repositories**. A provider may
already be published when a consumer's Nix check, lock update or push fails.
Flurry stops and reports what was published; it never force-pushes or automatically
rewrites published history.

Private run journals and trial clones are retained under `.flurry/runs/RUN_ID/`.
When the workspace is inside a Git worktree, Flurry automatically adds a literal,
workspace-scoped exclusion to Git's local `info/exclude` before journaling. This
also covers existing state, without modifying tracked `.gitignore` or the index.
Tracked state or overriding unignore rules cause an explicit refusal; Flurry does
not silently untrack files or overwrite those rules. Non-Git workspaces need no
Git metadata changes.

Git recovery refs under `refs/flurry/RUN_ID/` retain captured original state and
prepared commits. Do not delete them while investigating a failure. They can
contain unpublished source content; keep the state directory private.

```bash
flurry resume RUN_ID               # repeat original --exclude flags, if any
```

Resume checks configuration, repository inventory and exact checkout checkpoints,
then creates a fresh validated plan. Added repositories are not silently enrolled. This safely rechecks uncertain pushes instead of blindly replaying
them. Changed checkouts require a new reviewed plan. Interrupted promotion is
not automatically reset: inspect the journal, retained original/prepared refs and
owned stash before manual recovery. In particular, never apply a recovery stash
over unrelated newer edits. Successful runs also retain recovery objects; pruning
is deliberately not automatic in this version.

## Tests

```bash
python3 -m unittest discover -s tests -v
```

The suite uses controllable local Git remotes and real Nix where available, plus
permission/API fixtures and narrow dummies. It does not contact GitHub/GitLab or
operate on your workspace repositories. Real-Nix tests report a skip when Nix is
unavailable; the sync leg can be explicitly disabled with `FLURRY_REAL_NIX=0`.
The Nix package's build-time checks run the non-Nix leg; run the full command above
in a Nix-enabled development environment for complete verification.
