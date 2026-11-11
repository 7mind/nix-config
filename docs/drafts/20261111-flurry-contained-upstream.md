# Flurry: preserve history already containing its fetched baseline

Reported run: `0ae3a1d07a50472490a10ccc917d6b46`, repeated after `d3ff4e635eca4de9844eef335b3b088f`. Both fail in isolated Paddock rehearsal before publication. Local merged/cherry-picked duplicate patches replay after their follow-up when ordinary rebase flattens the DAG; the fetched upstream is already an ancestor of local HEAD.

## Reproduction and bounded correction

- Disposable real-Git regression creates original change + follow-up, cherry-picks both onto a sibling branch, then merges both. All three tests (clean, preserve split edits, staged commit) failed before the correction at the second copy's replay, as expected.
- Git.prepare now checks fetched baseline ancestry against current trial HEAD after its existing filter checks. Exit0 retains history; exit1 takes existing rebase path; other statuses fail closed. Final head capture, gitlink/filter/collision checks, restore rehearsal, source promotion and push safeguards are not bypassed.
- Tests cover retained merge commit IDs/tree, staged/unstaged/untracked preservation, explicit staged commit, behind/divergent baselines and ancestry-command failure.
- Full tests and flake evaluation run with finite background deadlines. Real workspace sync/push/history rewriting are not authorized or performed by this correction.

## Delivery status

Full suite ran238 tests:237 passed and one package-source test skipped for missing explicit Nixpkgs input; real-Nix sync fixtures ran. The package-source test then passed separately with the pinned Nixpkgs path. `nix flake check --no-build --no-write-lock-file` passed on the current x86_64-linux system.

An isolated local clone of the actual current Paddock history passed preparation against a local-only remote pinned to the failed run's baseline: current HEAD `8be5913944865bb515d1c35c96e94e2e2e799db9` and its tree were retained exactly; baseline `bd58faf87d7c5cf1f9e1a1c87857339c7d34f1c2`; original checkout stayed unchanged. Only file transport was allowed. Old failed rehearsal directories were not modified.

Independent read-only review found no blocking correctness issue. Keep the correction bounded: ancestor containment avoids needless rebasing and retains exact existing merge resolutions. Genuinely divergent history still follows the existing plain-rebase policy; this is not general merged-history preservation. Adding --rebase-merges alone would recreate merges, not guarantee preservation of prior manual merge-only edits.

Correction merged locally as `ac2c936c`. Corrected package build and package checks passed; immutable executable `/nix/store/mwc34yz3fw63bfbkfr9dww64fkbgsr9k-flurry-0.1.0/bin/flurry`, rooted at `~/.local/state/flurry-contained-base/result`. Its offline preserve/none workspace plan succeeds; this is not remote publication proof. A fresh read-only GitLab ref check still returned the tested baseline `bd58faf87d7c5cf1f9e1a1c87857339c7d34f1c2`.

The bare `flurry` command remains the older `/nix/store/wmvvq8xzmhzspn67m8378nha00r25ddr-flurry-0.1.0/bin/flurry` until normal configuration activation updates it. No global configuration or shadow wrapper was installed. To use the verified correction now:

```bash
~/.local/state/flurry-contained-base/result/bin/flurry sync --root ~/work/flakes --preserve --check none
```

That command retains the user's explicitly selected validation mode and publishes the selected workspace when run by the user. The assistant did not run it. Start a new sync, not resume of the old failure: the nix-config checkpoint changed with the correction. Existing journals and recovery data remain untouched.
