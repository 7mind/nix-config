from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Callable

from .git import Git, Prepared
from .nix import Nix
from .process import FlurryError, Runner, redact
from .source import Source, parse_source
from .state import Journal, config_digest, fingerprint, load_journal, workspace_lock
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


def optional_git(runner: Runner, repo: Path, *args: str) -> str | None:
    result = runner.call(["git", "-C", os.fspath(repo), *args], None, None, {}, False)
    if result.returncode == 1:
        return None
    if result.returncode:
        raise FlurryError(redact(result.stderr.decode(errors="replace")))
    return result.stdout.decode(errors="surrogateescape").strip()


def target_for(repo: Repository, runner: Runner) -> Target:
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
    remotes = runner.git_text(repo.path, "remote").splitlines()
    if remote not in remotes or not branch:
        raise FlurryError(f"{repo.name}: invalid rebase remote/branch {upstream}")
    baseline_url = runner.git_text(repo.path, "remote", "get-url", remote)
    if parse_source(baseline_url, repo.path) is None:
        raise FlurryError(f"{repo.name}: unsupported rebase remote")
    push_remote = repo.settings.push_remote or optional_git(runner, repo.path, "config", "--get", f"branch.{repo.branch}.pushRemote") or optional_git(runner, repo.path, "config", "--get", "remote.pushDefault") or optional_git(runner, repo.path, "config", "--get", f"branch.{repo.branch}.remote") or remote
    if push_remote not in remotes:
        raise FlurryError(f"{repo.name}: unknown push remote {push_remote}")
    push_ref = repo.settings.push_ref or f"refs/heads/{repo.branch}"
    if not push_ref.startswith("refs/heads/"):
        raise FlurryError(f"{repo.name}: push_ref must be a full refs/heads/ branch")
    runner.git(repo.path, "check-ref-format", push_ref)
    urls = runner.git_text(repo.path, "remote", "get-url", "--push", "--all", push_remote).splitlines()
    if len(urls) != 1:
        raise FlurryError(f"{repo.name}: exactly one push URL is required")
    push_source = parse_source(urls[0], repo.path)
    if push_source is None or push_source.repository_id != source.repository_id:
        raise FlurryError(f"{repo.name}: push URL differs from the provider origin; publication mapping is ambiguous")
    runner.git(repo.path, "check-ref-format", f"refs/heads/{branch}")
    return Target(repo, remote, f"refs/heads/{branch}", push_remote, push_ref, urls[0])


def plan_sync(config: Config, runner: Runner, nix: Nix, options: SyncOptions) -> SyncPlan:
    repositories = discover(config, runner)
    graph = build_graph(repositories, nix)
    targets = tuple(target_for(repo, runner) for repo in graph.order if not repo.excluded)
    if not targets:
        raise FlurryError("No selected repositories to synchronize")
    if options.dirty_mode not in ("reject", "preserve", "commit"):
        raise FlurryError("Invalid dirty-state policy")
    if options.dirty_mode == "commit" and (options.commit_scope not in ("staged", "all") or not options.message):
        raise FlurryError("Committing existing edits requires an explicit staged/all scope and message")
    if options.check_mode not in ("none", "eval", "full"):
        raise FlurryError("Invalid check mode")
    return SyncPlan(graph, targets, options, repositories)


def remote_head(runner: Runner, repo: Path, url: str, ref: str) -> str | None:
    lines = runner.git_text(repo, "ls-remote", "--refs", url, ref).splitlines()
    matches = [line.split() for line in lines if len(line.split()) == 2 and line.split()[1] == ref]
    if not matches:
        return None
    if len(matches) != 1 or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", matches[0][0]):
        raise FlurryError("Malformed/ambiguous remote ref response")
    return matches[0][0]


def default_branch(runner: Runner, repo: Path, source: Source) -> str:
    if source.clone_url is None:
        raise FlurryError("Cannot resolve branch for non-Git source")
    text = runner.git_text(repo, "ls-remote", "--symref", source.clone_url, "HEAD")
    refs = [line.split()[1] for line in text.splitlines() if line.startswith("ref: ") and line.endswith("\tHEAD")]
    if len(refs) != 1 or not refs[0].startswith("refs/heads/"):
        raise FlurryError(f"Cannot resolve default branch of {source.repository_id}; declare an explicit input ref")
    return refs[0]


def validate_edges(graph: WorkspaceGraph, targets: dict[str, Target], runner: Runner) -> None:
    for edge in graph.edges:
        if edge.consumer.excluded or edge.provider.excluded or edge.input.source is None or edge.input.source.rev is not None:
            continue
        source = edge.input.source
        target = targets[edge.provider.name]
        expected = f"refs/heads/{source.ref.removeprefix('refs/heads/')}" if source.ref is not None else default_branch(runner, edge.provider.path, source)
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
        with workspace_lock(config.root):
            if guard is not None:
                if config_digest(config.root) != guard.configuration:
                    raise FlurryError("Configuration changed before resume acquired the workspace lock")
                for path, expected in guard.checkpoints:
                    if fingerprint(path, self.runner) != expected:
                        raise FlurryError(f"{path.name}: checkout changed before resume; refusing automatic retry")
            plan = plan_sync(config, self.runner, self.nix, options)
            selected_inventory = inventory(plan.repositories)
            if guard is not None and selected_inventory != guard.inventory:
                raise FlurryError("Workspace inventory changed since the interrupted run; review a new plan")
            journal = Journal(config.root, options.to_dict())
            journal.document["inventory"] = [entry.to_dict() for entry in selected_inventory]
            journal.save()
            published: list[str] = []
            try:
                targets = {target.repository.name: target for target in plan.targets}
                for target in plan.targets:
                    repo = target.repository
                    journal.repository(repo.name, {
                        "path": os.fspath(repo.path), "state": "original",
                        "checkpoint": fingerprint(repo.path, self.runner),
                        "push_ref": target.push_ref, "push_remote": target.push_remote,
                    })
                    if options.dirty_mode == "preserve":
                        touched = self.runner.git(repo.path, "diff", "--name-only", "HEAD", "--", "flake.nix", "flake.lock")
                        if touched:
                            raise FlurryError(f"{repo.name}: preserve mode cannot publish locks over pre-existing flake.nix/flake.lock edits; commit or reconcile those files first")
                validate_edges(plan.graph, targets, self.runner)
                prepared: dict[str, Prepared] = {}
                for index, target in enumerate(plan.targets):
                    name = target.repository.name
                    journal.action(f"preparing:{name}")
                    self.report(f"Rehearsing {name}")
                    item = self.git.prepare(target.repository.path, journal.directory / f"trial-{index}", target.baseline, options.dirty_mode, options.message, options.commit_scope, remote=target.remote)
                    prepared[name] = item
                    journal.repository(name, {"state": "prepared", "head": item.head, "trial": os.fspath(item.trial)})
                    self._check_push_base(target, item)
                trial_repositories = tuple(
                    replace(repo, path=prepared[repo.name].trial, head=prepared[repo.name].head)
                    if repo.name in prepared else repo
                    for repo in discover(config, self.runner)
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
                    before = frozen_lock(item.trial, frozen_ids)
                    if edges:
                        self.report(f"Updating {name}: {', '.join(edge.input.name for edge in edges)}")
                        self.nix.update(item.trial, tuple(dict.fromkeys(edge.input.name for edge in edges)))
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
                        self.nix.check(item.trial, options.check_mode == "full")
                    self.git.commit_lock(item)
                    self.git.rehearse_restore(item)
                    self._check_push_base(target, item)
                    self.git.verify(item)
                    journal.repository(name, {"head": item.head})
                    journal.action(f"promoting:{name}")
                    recovery = self.git.promote(item, journal.run_id)
                    journal.repository(name, {
                        "state": "promoted", "checkpoint": fingerprint(target.repository.path, self.runner),
                        "recovery": {"stash_ref": recovery.stash_ref, "prepared_ref": recovery.prepared_ref,
                                     "original_head": item.original.head, "marker": item.marker,
                                     "phase": recovery.phase},
                    })
                    journal.action(f"pushing:{name}")
                    self.report(f"Publishing {name} -> {target.push_remote}/{target.push_ref}")
                    self.git.push(target.repository.path, target.push_remote, target.push_ref, item.head)
                    published.append(name)
                    journal.repository(name, {"state": "published", "checkpoint": fingerprint(target.repository.path, self.runner)})
                journal.action("complete")
                journal.finish("complete", "All selected repositories and generated locks published")
                return journal
            except BaseException as error:
                detail = redact(str(error))
                journal.finish("failed", detail)
                done = ", ".join(published) or "none"
                if isinstance(error, (KeyboardInterrupt, SystemExit)):
                    self.report(f"Interrupted. Published: {done}. Run: {journal.path}")
                    raise
                raise FlurryError(f"{detail}\nPublished: {done}. Run journal/recovery data: {journal.path}\nNo published history was rolled back.") from error

    def _check_push_base(self, target: Target, item: Prepared) -> None:
        remote = remote_head(self.runner, item.trial, target.push_url, target.push_ref)
        if remote is None:
            return
        self.runner.git(item.trial, "fetch", "--no-tags", "--no-recurse-submodules", target.push_url, f"+{target.push_ref}:refs/flurry/push-base")
        result = self.runner.call(["git", "-C", os.fspath(item.trial), "merge-base", "--is-ancestor", remote, item.head], None, None, {}, False)
        if result.returncode == 1:
            raise FlurryError(f"{target.repository.name}: planned push is not fast-forward; reconcile published history manually (no force pushes)")
        if result.returncode:
            raise FlurryError("Could not verify push ancestry")

    def resume(self, config: Config, run_id: str) -> Journal:
        with workspace_lock(config.root):
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
                if fingerprint(path, self.runner) != value["checkpoint"]:
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
