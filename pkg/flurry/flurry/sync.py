from __future__ import annotations

import json
import os
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, replace
from pathlib import Path
from threading import Lock
from typing import Callable

from .clean import CleanCheckout, Context, clean_checkout, config_values, physical_file, settings
from .git import Git, Prepared, Recovery
from .nix import Nix
from .process import FlurryError, Runner, redact, remote_head
from .source import Source, parse_source
from .state import Journal, config_digest, full_checkpoint, matches_checkpoint, load_journal, workspace_lock
from .workspace import Config, Repository, WorkspaceGraph, build_graph, discover, provider_identities


@dataclass(frozen=True)
class SyncOptions:
    dirty_mode: str
    commit_scope: str | None
    message: str | None
    check_mode: str
    excludes: tuple[str, ...]

    def to_dict(self) -> dict[str, object]:
        return {
            "dirty_mode": self.dirty_mode, "commit_scope": self.commit_scope,
            "message": self.message, "check_mode": self.check_mode,
            "excludes": list(self.excludes),
        }


@dataclass(frozen=True)
class Target:
    repository: Repository
    remote: str
    baseline: str
    push_remote: str
    push_ref: str
    push_url: str
    baseline_url: str | None = None

    def to_dict(self) -> dict[str, object]:
        return {
            "name": self.repository.name, "path": os.fspath(self.repository.path),
            "branch": self.repository.branch, "rebase": f"{self.remote}/{self.baseline}",
            "push_remote": self.push_remote, "push_ref": self.push_ref,
            "head": self.repository.head,
        }


@dataclass(frozen=True)
class InventoryEntry:
    name: str
    path: str
    branch: str | None
    excluded: bool
    identities: tuple[str, ...]
    storage: str

    def to_dict(self) -> dict[str, object]:
        return {"name": self.name, "path": self.path, "branch": self.branch,
                "excluded": self.excluded, "identities": list(self.identities), "storage": self.storage}

    @classmethod
    def from_dict(cls, value: object) -> InventoryEntry:
        if not isinstance(value, dict) or not all(isinstance(value.get(key), str) for key in ("name", "path", "storage")):
            raise FlurryError("Malformed run inventory")
        branch, excluded, identities = (value.get(key) for key in ("branch", "excluded", "identities"))
        if (branch is not None and not isinstance(branch, str)) or type(excluded) is not bool or not isinstance(identities, list) or not all(isinstance(item, str) for item in identities):
            raise FlurryError("Malformed run inventory")
        return cls(value["name"], value["path"], branch, excluded, tuple(identities), value["storage"])


def inventory(repositories: tuple[Repository, ...]) -> tuple[InventoryEntry, ...]:
    return tuple(InventoryEntry(repo.name, os.fspath(repo.settings.path), repo.branch, repo.excluded,
                                tuple(sorted(provider_identities(repo))), os.fspath(repo.common_dir))
                 for repo in sorted(repositories, key=lambda item: item.name))


@dataclass(frozen=True)
class SyncPlan:
    graph: WorkspaceGraph
    targets: tuple[Target, ...]
    options: SyncOptions
    repositories: tuple[Repository, ...]

    def to_dict(self) -> dict[str, object]:
        return {
            "provisional": True, "notice": "Offline plan: no remotes have been fetched or push access established.",
            "options": self.options.to_dict(),
            "order": [target.repository.name for target in self.targets],
            "repositories": [target.to_dict() for target in self.targets],
            "edges": [{"provider": edge.provider.name, "consumer": edge.consumer.name,
                       "input": edge.input.name} for edge in self.graph.edges],
        }


def target_for(repo: Repository, runner: Runner, config: bytes | None = None) -> Target:
    if repo.branch is None:
        raise FlurryError(f"{repo.name}: detached HEAD; check out a branch before sync")
    if repo.origin is None:
        raise FlurryError(f"{repo.name}: missing origin")
    source = parse_source(repo.origin, repo.path)
    if source is None or source.clone_url is None:
        raise FlurryError(f"{repo.name}: unsupported origin")
    if repo.settings.source is not None and repo.settings.source.repository_id != source.repository_id:
        raise FlurryError(f"{repo.name}: configured source differs from origin; refusing ambiguous publication")
    upstream = repo.settings.rebase_onto or repo.upstream
    if upstream is None:
        raise FlurryError(f"{repo.name}: no upstream; configure rebase_onto")
    upstream = upstream.removeprefix("refs/remotes/")
    if "/" not in upstream:
        raise FlurryError(f"{repo.name}: rebase_onto must name a remote branch")
    remote, branch = upstream.split("/", 1)
    if not remote or not branch:
        raise FlurryError(f"{repo.name}: invalid rebase remote/branch {upstream}")
    baseline_url = repo.origin if remote == "origin" else runner.git_text(repo.path, "remote", "get-url", remote)
    if parse_source(baseline_url, repo.path) is None:
        raise FlurryError(f"{repo.name}: unsupported rebase remote")
    values = settings(config_values(repo.path, runner) if config is None else config)
    push_remote = (repo.settings.push_remote or values.get(f"branch.{repo.branch}.pushremote") or values.get("remote.pushdefault")
                   or values.get(f"branch.{repo.branch}.remote") or remote)
    push_ref = repo.settings.push_ref or f"refs/heads/{repo.branch}"
    if not push_ref.startswith("refs/heads/"):
        raise FlurryError(f"{repo.name}: push_ref must be a full refs/heads/ branch")
    runner.check_branch(repo.path, push_ref)
    urls = runner.git_text(repo.path, "remote", "get-url", "--push", "--all", push_remote).splitlines()
    if len(urls) != 1:
        raise FlurryError(f"{repo.name}: exactly one push URL is required")
    push_source = parse_source(urls[0], repo.path)
    if push_source is None or push_source.repository_id != source.repository_id:
        raise FlurryError(f"{repo.name}: push URL differs from the provider origin; publication mapping is ambiguous")
    runner.check_branch(repo.path, f"refs/heads/{branch}")
    return Target(repo, remote, f"refs/heads/{branch}", push_remote, push_ref, urls[0], baseline_url)


def validate_dirty_policy(repository: Repository, runner: Runner, options: SyncOptions) -> None:
    path = repository.path
    if options.dirty_mode == "reject":
        if runner.git(path, "--no-optional-locks", "status", "--porcelain=v1", "--untracked-files=all", "-z"):
            raise FlurryError(f"{repository.name}: Dirty source rejected; choose --preserve or an explicit --commit scope")
        return
    if options.dirty_mode == "commit" and options.commit_scope == "all":
        return
    flake_paths = (":(top,literal)flake.nix", ":(top,literal)flake.lock")
    diff_options = ("diff", "--name-only", "--no-renames", "--no-ext-diff", "--no-textconv", "-z")
    retained = runner.git(path, "--no-optional-locks", *diff_options, "--", *flake_paths)
    retained = retained or runner.git(path, "--no-optional-locks", "ls-files", "--others", "--exclude-standard", "-z", "--", *flake_paths)
    if options.dirty_mode == "preserve":
        retained = retained or runner.git(path, "--no-optional-locks", *diff_options, "--cached", "HEAD", "--", *flake_paths)
    if retained:
        if options.dirty_mode == "preserve":
            raise FlurryError(f"{repository.name}: preserve mode cannot publish locks over pre-existing flake.nix/flake.lock edits; commit or reconcile those files first")
        raise FlurryError(f"{repository.name}: --commit staged leaves pre-existing flake.nix/flake.lock edits outside the commit; stage or reconcile those files first")


def plan_sync(config: Config, runner: Runner, nix: Nix, options: SyncOptions, *, witnesses: dict[str, CleanCheckout] | None = None) -> SyncPlan:
    declarations = {}
    contexts: dict[Path, Context] = {}
    repositories = discover(config, runner, declarations=declarations, nix=nix, contexts=contexts if witnesses is not None else None)
    graph = build_graph(repositories, nix, declarations=declarations)
    configs = {repo.name: context.config if (context := contexts.get(repo.path)) else config_values(repo.path, runner)
               for repo in graph.order if not repo.excluded}
    targets = tuple(target_for(repo, runner, configs[repo.name]) for repo in graph.order if not repo.excluded)
    if not targets:
        raise FlurryError("No selected repositories to synchronize")
    if options.dirty_mode not in ("reject", "preserve", "commit"):
        raise FlurryError("Invalid dirty-state policy")
    if options.dirty_mode == "commit" and (options.commit_scope not in ("staged", "all") or not options.message):
        raise FlurryError("Committing existing edits requires an explicit staged/all scope and message")
    if options.check_mode not in ("none", "eval", "full"):
        raise FlurryError("Invalid check mode")
    for target in targets:
        repo = target.repository
        if witnesses is not None and (context := contexts.get(repo.path)) is not None:
            if not context.config_matches(runner):
                raise FlurryError(f"{repo.name}: Git configuration changed during target resolution")
            witness = clean_checkout(repo.path, runner, context=context, observed=repo.checkout_refs)
            if witness is not None:
                witnesses[repo.name] = witness
                continue
        validate_dirty_policy(repo, runner, options)
    return SyncPlan(graph, targets, options, repositories)


def default_branch(runner: Runner, repo: Path, source: Source) -> str:
    if source.clone_url is None:
        raise FlurryError("Cannot resolve branch for non-Git source")
    text = runner.git_text(repo, "ls-remote", "--symref", source.clone_url, "HEAD")
    refs = [line.split()[1] for line in text.splitlines() if line.startswith("ref: ") and line.endswith("\tHEAD")]
    if len(refs) != 1 or not refs[0].startswith("refs/heads/"):
        raise FlurryError(f"Cannot resolve default branch of {source.repository_id}; declare an explicit input ref")
    return refs[0]


def validate_edges(graph: WorkspaceGraph, targets: dict[str, Target], runner: Runner) -> None:
    defaults: dict[tuple[Path, str | None], str] = {}
    for edge in graph.edges:
        if edge.consumer.excluded or edge.provider.excluded or edge.input.source is None or edge.input.source.rev is not None:
            continue
        source = edge.input.source
        target = targets[edge.provider.name]
        if source.ref is None:
            key = (edge.provider.path, source.clone_url)
            if key not in defaults:
                defaults[key] = default_branch(runner, edge.provider.path, source)
            expected = defaults[key]
        else:
            expected = f"refs/heads/{source.ref.removeprefix('refs/heads/')}"
        if expected != target.push_ref:
            raise FlurryError(f"{edge.consumer.name}.{edge.input.name} tracks {expected}, but {edge.provider.name} would push {target.push_ref}")


def frozen_lock(path: Path, identities: set[str]) -> dict[str, list[str]]:
    lock = path / "flake.lock"
    if not lock.exists():
        return {}
    try:
        data = json.loads(lock.read_text())
        nodes = data["nodes"]
        if not isinstance(nodes, dict):
            raise ValueError("nodes must be an object")
        result: dict[str, list[str]] = {}
        for node in nodes.values():
            if not isinstance(node, dict) or "locked" not in node:
                continue
            source = parse_source(node["locked"], path)
            if source is not None and source.repository_id in identities:
                result.setdefault(source.repository_id, []).append(json.dumps(node["locked"], sort_keys=True))
        return {key: sorted(set(value)) for key, value in result.items()}
    except (ValueError, KeyError, TypeError) as error:
        raise FlurryError(f"Invalid lock file {lock}: {error}") from error


@dataclass(frozen=True)
class ResumeGuard:
    configuration: str
    checkpoints: tuple[tuple[Path, str], ...]
    inventory: tuple[InventoryEntry, ...]


class Sync:
    def __init__(self, runner: Runner, nix: Nix, git: Git, report: Callable[[str], None]):
        self.runner = runner
        self.nix = nix
        self.git = git
        self.report = report

    def run(self, config: Config, options: SyncOptions, guard: ResumeGuard | None) -> Journal:
        with workspace_lock(config.root, self.runner):
            if guard is not None:
                if config_digest(config.root) != guard.configuration:
                    raise FlurryError("Configuration changed before resume acquired the workspace lock")
                for path, expected in guard.checkpoints:
                    if not matches_checkpoint(path, self.runner, expected):
                        raise FlurryError(f"{path.name}: checkout changed before resume; refusing automatic retry")
            witnesses: dict[str, CleanCheckout] = {}
            plan = plan_sync(config, self.runner, self.nix, options, witnesses=witnesses)
            selected_inventory = inventory(plan.repositories)
            if guard is not None and selected_inventory != guard.inventory:
                raise FlurryError("Workspace inventory changed since the interrupted run; review a new plan")
            journal = Journal(config.root, options.to_dict())
            journal.document["inventory"] = [entry.to_dict() for entry in selected_inventory]
            journal.save()
            published: list[str] = []
            recoveries: dict[str, Recovery] = {}
            try:
                targets = {target.repository.name: target for target in plan.targets}
                for target in plan.targets:
                    repo = target.repository
                    journal.repository(repo.name, {
                        "path": os.fspath(repo.path), "state": "original",
                        "checkpoint": witnesses[repo.name].checkpoint if repo.name in witnesses else full_checkpoint(repo.path, self.runner),
                        "push_ref": target.push_ref, "push_remote": target.push_remote,
                    })
                validate_edges(plan.graph, targets, self.runner)
                prepared = self._prepare_all(plan.targets, options, journal, witnesses)
                proven = {repo.path: repo for repo in plan.repositories if repo.name in witnesses} if all(
                    item.clean_trial is not None for item in prepared.values()) else {}
                current = discover(config, self.runner, verified=proven, nix=self.nix)
                if inventory(current) != selected_inventory:
                    raise FlurryError("Workspace inventory changed during rehearsal; refusing publication")
                trial_repositories = tuple(
                    replace(repo, path=prepared[repo.name].trial, head=prepared[repo.name].head)
                    if repo.name in prepared else repo
                    for repo in current
                )
                graph = build_graph(trial_repositories, self.nix)
                validate_edges(graph, targets, self.runner)
                for item in prepared.values():
                    self.git.verify(item)
                active_ids = {identity for repo in trial_repositories if not repo.excluded for identity in provider_identities(repo)}
                frozen_ids = {identity for repo in trial_repositories if repo.excluded for identity in provider_identities(repo)} - active_ids
                for repo in graph.order:
                    if repo.excluded:
                        continue
                    name = repo.name
                    target = targets[name]
                    item = prepared[name]
                    edges = [edge for edge in graph.edges if edge.consumer.name == name and not edge.provider.excluded and edge.input.source is not None and edge.input.source.rev is None]
                    journal.action(f"locking:{name}")
                    if physical_file(item.trial / "flake.lock") != item.lock_state:
                        raise FlurryError(f"{name}: trial flake.lock changed before lock generation")
                    before = frozen_lock(item.trial, frozen_ids)
                    if edges:
                        self.report(f"Updating {name}: {', '.join(edge.input.name for edge in edges)}")
                        self.nix.update(item.trial, tuple(dict.fromkeys(edge.input.name for edge in edges)))
                        item.lock_state = physical_file(item.trial / "flake.lock")
                        actual = self.nix.locked_inputs(item.trial)
                        for edge in edges:
                            locked = actual.get(edge.input.name)
                            provider = prepared[edge.provider.name]
                            if locked is None or locked.rev != provider.head or locked.repository_id != edge.input.source.repository_id:
                                observed = "missing" if locked is None else locked.rev
                                raise FlurryError(f"{name}.{edge.input.name}: expected published {provider.head}, observed {observed}; refusing a stale/misdirected lock")
                    if frozen_lock(item.trial, frozen_ids) != before:
                        raise FlurryError(f"{name}: lock update crossed an excluded provider boundary")
                    if options.check_mode != "none" and (item.trial / "flake.nix").is_file():
                        journal.action(f"checking:{name}")
                        self.nix.check(item.trial, options.check_mode == "full", report=self.report)
                    self.git.commit_lock(item)
                    self._check_push_base(target, item)

                    if self.git.requires_promotion(item):
                        def before_source_write() -> None:
                            journal.repository(name, {"head": item.head}, action=f"promoting:{name}")

                        recovery = self.git.promote(item, journal.run_id, before_source_write=before_source_write)
                        recoveries[name] = recovery
                        journal.repository(name, {
                            "state": "promoted", "checkpoint": full_checkpoint(target.repository.path, self.runner),
                            "recovery": {"stash_ref": recovery.stash_ref, "remaining_ref": recovery.remaining_ref,
                                         "prepared_ref": recovery.prepared_ref,
                                         "original_head": item.original.head, "marker": item.marker,
                                         "phase": recovery.phase},
                        })
                    journal.action(f"pushing:{name}")
                    self.report(f"Publishing {name} -> {target.push_remote}/{target.push_ref}")
                    self.git.verify_trial(item)
                    last_check = None
                    if isinstance(item.original, CleanCheckout):
                        last_check = lambda: self.git.verify(item)
                    else:
                        if name in recoveries:
                            self.git.verify_promoted(recoveries[name])
                        else:
                            self.git.verify(item)
                        urls = self.runner.git_text(item.repo, 'remote', 'get-url', '--push', '--all', target.push_remote).splitlines()
                        if urls != [target.push_url]:
                            raise FlurryError(f'{name}: push URL changed during rehearsal')
                    self.git.push(target.repository.path, target.push_remote, target.push_ref, item.head,
                                  push_url=target.push_url, verify_source=last_check)
                    published.append(name)
                    checkpoint = (item.original.checkpoint if isinstance(item.original, CleanCheckout) and item.original.matches(self.runner)
                                  else full_checkpoint(target.repository.path, self.runner))
                    journal.repository(name, {"state": "published", "checkpoint": checkpoint})
                for name, recovery in recoveries.items():
                    journal.action(f"cleaning:{name}")
                    self.git.cleanup(recovery)
                    journal.repository(name, {"recovery_refs_cleaned": True})
                journal.action("complete")
                journal.finish("complete", "All selected repositories and generated locks published; current-run recovery refs removed")
                return journal
            except BaseException as error:
                detail = redact(str(error))
                journal.finish("failed", detail)
                done = ", ".join(published) or "none"
                if isinstance(error, (KeyboardInterrupt, SystemExit)):
                    self.report(f"Interrupted. Published: {done}. Run: {journal.path}")
                    raise
                raise FlurryError(f"{detail}\nPublished: {done}. Run journal/recovery data: {journal.path}\nNo published history was rolled back.") from error

    def _prepare_all(self, targets: tuple[Target, ...], options: SyncOptions, journal: Journal, witnesses: dict[str, CleanCheckout]) -> dict[str, Prepared]:
        max_preparations = 4
        storage_locks = {target.repository.common_dir: Lock() for target in targets}

        def prepare(index: int, target: Target) -> Prepared:
            # Linked worktrees share Git metadata; never capture them concurrently.
            with storage_locks[target.repository.common_dir]:
                item = self.git.prepare(target.repository.path, journal.directory / f"trial-{index}", target.baseline, options.dirty_mode, options.message, options.commit_scope, remote=target.remote, witness=witnesses.get(target.repository.name), remote_url=target.baseline_url)
                item.lock_state = physical_file(item.trial / "flake.lock")
                self._check_push_base(target, item)
                return item

        prepared: dict[str, Prepared] = {}
        journal.action("preparing")
        with ThreadPoolExecutor(max_workers=min(max_preparations, len(targets))) as executor:
            futures = {}
            try:
                for index, target in enumerate(targets):
                    self.report(f"Rehearsing {target.repository.name}")
                    futures[executor.submit(prepare, index, target)] = target.repository.name
                for future in as_completed(futures):
                    name = futures[future]
                    item = future.result()
                    prepared[name] = item
                    journal.repository(name, {"state": "prepared", "head": item.head, "trial": os.fspath(item.trial)})
            except BaseException:
                for future in futures:
                    future.cancel()
                # Drain running rehearsals before releasing the workspace lock or failing the journal.
                raise
        return {target.repository.name: prepared[target.repository.name] for target in targets}

    def _check_push_base(self, target: Target, item: Prepared) -> None:
        remote = remote_head(self.runner, item.trial, target.push_url, target.push_ref)
        if remote is None or remote == item.head:
            return
        if remote != item.baseline:
            self.runner.git(item.trial, "fetch", "--no-tags", "--no-recurse-submodules", target.push_url, f"+{target.push_ref}:refs/flurry/push-base")
        result = self.runner.call(["git", "-C", os.fspath(item.trial), "merge-base", "--is-ancestor", remote, item.head], None, None, {}, False)
        if result.returncode == 1:
            raise FlurryError(f"{target.repository.name}: planned push is not fast-forward; reconcile published history manually (no force pushes)")
        if result.returncode:
            raise FlurryError("Could not verify push ancestry")

    def resume(self, config: Config, run_id: str) -> Journal:
        with workspace_lock(config.root, self.runner):
            data = load_journal(config.root, run_id)
            if data.get("status") == "complete":
                raise FlurryError("This run is already complete")
            if data.get("config_digest") != config_digest(config.root):
                raise FlurryError("Configuration changed; inspect recovery data and start a new plan")
            action = data.get("action")
            if not isinstance(action, str) or action.startswith("promoting:"):
                raise FlurryError("Interrupted promotion requires manual recovery before resuming; inspect the retained trial and Git recovery refs")
            repositories = data.get("repositories")
            if not isinstance(repositories, dict):
                raise FlurryError("Malformed repository journal")
            checkpoints: list[tuple[Path, str]] = []
            for name, value in repositories.items():
                if not isinstance(value, dict) or not isinstance(value.get("path"), str) or not isinstance(value.get("checkpoint"), str):
                    raise FlurryError("Malformed repository checkpoint")
                path = Path(value["path"])
                if path.is_symlink() or not path.resolve().is_relative_to(config.root):
                    raise FlurryError("Repository checkpoint escapes the workspace")
                if not matches_checkpoint(path, self.runner, value["checkpoint"]):
                    raise FlurryError(f"{name}: checkout changed since the last checkpoint; refusing automatic resume")
                checkpoints.append((path, value["checkpoint"]))
            raw = data.get("options")
            if not isinstance(raw, dict) or not isinstance(raw.get("excludes"), list):
                raise FlurryError("Malformed run options")
            mode, scope, message, check = (raw.get(key) for key in ("dirty_mode", "commit_scope", "message", "check_mode"))
            if not isinstance(mode, str) or not isinstance(check, str) or (scope is not None and not isinstance(scope, str)) or (message is not None and not isinstance(message, str)):
                raise FlurryError("Malformed run options")
            excludes = raw["excludes"]
            if not all(isinstance(item, str) for item in excludes):
                raise FlurryError("Malformed exclusions")
            if config.excludes != tuple(excludes):
                raise FlurryError("Exclusions differ from the interrupted run; repeat its original --exclude flags")
            raw_inventory = data.get("inventory")
            if not isinstance(raw_inventory, list):
                raise FlurryError("Run has no valid inventory; inspect recovery data and create a new plan")
            previous_inventory = tuple(InventoryEntry.from_dict(entry) for entry in raw_inventory)
            options = SyncOptions(mode, scope, message, check, tuple(excludes))
        self.report(f"Resuming {run_id} with a fresh validated plan; uncertain pushes are rechecked, never force-replayed")
        return self.run(config, options, ResumeGuard(str(data["config_digest"]), tuple(checkpoints), previous_inventory))
