---
name: flurry
description: >-
  Maintain a workspace of related Nix/Git repositories with Flurry: inspect
  sibling checkouts, order provider/consumer updates, rebase and publish changes,
  propagate flake.lock revisions, preserve unfinished edits, bootstrap writable
  dependencies, and resume interrupted syncs. Use when asked to sync/publish a
  flake workspace or update downstream locks after local provider changes,
  BEFORE writing bash/Python loops for those operations. Not for general package
  upgrade audits, arbitrary external-input upgrades, deployments, or one-repo
  edits unrelated to workspace synchronization.
---

# Flurry workspace maintenance

Use Flurry instead of implementing repository discovery, dependency sorting,
Git preservation/rebase/push loops, lock propagation, permission probing or
recovery in ad hoc bash/Python. Small commands to inspect its output are fine.
If Flurry refuses an unsupported arrangement, report the blocker; do not silently
replace its safety checks with a custom script.

## Establish scope before execution

- Select the **workspace directory containing the repositories**, not the
  tool checkout or a single consumer. Pass `--root /absolute/workspace` explicitly.
- Read `flurry.toml` and `flurry.local.toml` if present. Inspect branch, upstream,
  dirty state, exclusions and push destinations before modifying anything.
- Use `flurry --help` and the selected command's `--help` to confirm available
  flags. Authoritative source/docs live in `nix-config/pkg/flurry`, not necessarily
  a sibling checkout named `flurry`. If absent from PATH, use
  `nix run /path/to/nix-config#flurry -- ...` or its `pkg/flurry/bin/flurry`.
- A request to inspect, plan or update locks does **not** by itself authorize
  publishing all selected repositories. Confirm publication scope if ambiguous.
  This skill grants no push, commit-scope expansion, authentication or deployment
  authority. Follow the environment skill when sandbox/host boundaries apply.

## Inspect and plan first

```bash
flurry status --root /absolute/workspace --json
flurry graph --root /absolute/workspace --json
flurry plan --root /absolute/workspace --preserve --json
```

`status`, `graph`, `plan` and `sync --dry-run` do not fetch, commit or push.
Plans are local and provisional, not evidence of fresh remote state or successful
rebase/restore/validation. Match the plan's edit policy, exclusions and validation
mode to the intended execution; nonzero exit means stop and inspect the error.
Use repeated, quoted `--exclude 'pattern'` flags to narrow scope. Do not enroll
scratch/topic worktrees just because discovery finds them. Independent linked
worktrees are not deduplicated; ambiguous providers need selection or exclusion.
An excluded repository with no included matching provider is a frozen boundary,
as are fixed-revision inputs: neither authorizes rewriting `flake.nix` or picking
a different branch.

## Synchronize only within authorized publication scope

Choose one edit policy and use the same policy in `plan` and `sync`:

| Policy | Command suffix | Effect on existing edits |
|---|---|---|
| Clean sources | none | Refuses dirty sources |
| Preserve unfinished work | `--preserve` | Keeps existing edits local, including staged/unstaged distinction |
| Commit selected edits | `--commit staged --message '…'` | Commits staged changes before sync |
| Commit all visible edits | `--commit all --message '…'` | Includes visible untracked files; requires explicit scope review |

**Every sync policy can commit and push generated lock changes.**
`--without-committing` is only an alias for `--preserve`, not a no-commit/no-push
mode. Rebase may replace local commit IDs. Preserve mode refuses pre-existing
root flake-file edits that overlap generated lock work; reconcile those explicitly,
never switch to `--commit all` merely to clear a refusal.

For an authorized preserve-mode run, after reviewing its matching plan:

```bash
flurry sync --root /absolute/workspace --preserve --json
```

Flurry rehearses rebases/restorations, then publishes providers before updating,
checking, committing and publishing consumers' locks. It propagates actual
provider revisions, not speculative commit IDs. Unrelated external dependencies
are not deliberately upgraded; transitive lock nodes can change with a provider.
Validation defaults to `--check eval` (`nix flake check --no-build`);
`--check full` also builds checks. Do not weaken validation to `--check none` to
bypass a failure. Flurry never activates Home Manager/NixOS or deploys anything.

Keep selected checkouts exclusive during execution: no concurrent agents,
editors or Git commands modifying them. Flurry's lock coordinates only Flurry
instances. Do not create a worktree solely to run maintenance: discovery and
publication must target the agreed checkouts. Use normal task worktrees for
code/config edits, not as an implicit substitute provider.

## Bootstrap writable dependency checkouts

```bash
flurry pull application --root /absolute/workspace --dry-run
# Only after reviewing destinations, access evidence, skips and blockers:
flurry pull application --root /absolute/workspace
```

`pull` means **clone writable transitive dependencies**, not `git pull`.
Use a local/configured name or explicit flake reference (e.g.
`github:owner/application`). The dry run queries metadata and authenticated
permission APIs: it is not offline. Affirmative code-write permission is required.
GitHub uses `gh`; GitLab uses `glab` and custom GitLab hosts must be explicitly
listed in `gitlab_hosts`. Never authorize credential use at an arbitrary host
merely because an input URL names it; do not automate login or broaden grants.

New clones use branch tips, not historical locked revisions. Matching existing
checkouts are reused without fetching or switching branches. No forks or remote
branches are created; permission evidence does not guarantee push credentials or
branch-protection acceptance. Use an exclusively used, trusted workspace: path
checks do not protect against concurrent ancestor-directory replacement. Do not
overwrite conflicting destinations.

Optional `flurry init --root /absolute/workspace` creates a no-overwrite config
without Git/Nix/network access; configuration is not required. Do not initialize
or change exclusions/remote overrides just to evade a blocker.

## Failure, recovery and verification

There is **no atomic transaction across remotes**: providers may already have
been published when a consumer fails. Read the reported error and retained run
journal before retrying. Report published, pending and uncertain results separately.
Do not reset source checkouts, force-push, bypass hooks, apply recovery stashes
onto newer edits, or delete locks/recovery data to make a retry proceed.
Preservation covers Git-visible content/executable bits, not ignored files,
ownership, ACLs or timestamps; do not treat it as a full filesystem backup.

Private journals/trial clones live under `.flurry/runs/RUN_ID/`; recovery refs
under `refs/flurry/RUN_ID/` can contain unpublished source. Do not upload them.
If checkpoints and configuration are unchanged and retry is authorized:

```bash
flurry resume RUN_ID --root /absolute/workspace
```

Repeat the original `--exclude` flags. Resume revalidates inventory, configuration
and exact checkpoints, then replans; it is not blind replay. Changed checkouts
need a new reviewed plan; interrupted promotion may require manual investigation.
Never remove a workspace lock to bypass another running operation.

Verify the command's exit status and final journal/output, then inspect
`flurry status --root /absolute/workspace --json`. State which repositories and
locks were published, which edits remain local, validation mode and run ID.
Local status alone does not prove remote publication. If work is blocked, retain
recovery evidence and report the exact unsupported condition rather than claiming
completion or silently implementing a fallback.
