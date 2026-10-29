from __future__ import annotations

import ctypes
import errno
import fnmatch
import json
import os
import re
import shutil
import sys
import tempfile
from dataclasses import asdict, dataclass, replace
from pathlib import Path
from typing import TYPE_CHECKING, Mapping

from .permissions import Permission, PermissionState, Permissions
from .process import FlurryError, Runner
from .source import Source, parse_source

if TYPE_CHECKING:
    from .nix import Nix

MAX_LOCK_NODES = 4096
MAX_LOCK_BYTES = 8 * 1024 * 1024


@dataclass(frozen=True)
class PullEntry:
    repository_id: str
    url: str
    clone_url: str
    destination: str
    sources: tuple[str, ...]
    locked_revisions: tuple[str, ...]
    branch: str | None
    action: str
    permission: Permission | None
    reason: str


@dataclass(frozen=True)
class PullPlan:
    root_ref: str
    root: str
    provenance: str
    entries: tuple[PullEntry, ...]
    issues: tuple[str, ...]
    warnings: tuple[str, ...]

    @property
    def complete(self) -> bool:
        return not self.issues and all(entry.action != "blocked" for entry in self.entries)

    def to_dict(self) -> dict[str, object]:
        return asdict(self) | {"complete": self.complete}


@dataclass(frozen=True)
class PullResult:
    repository_id: str
    destination: str
    action: str
    revision: str | None
    reason: str

    def to_dict(self) -> dict[str, object]:
        return asdict(self)


def _destination(root: Path, relative: str) -> Path:
    for ancestor in (*reversed(root.parents), root):
        if ancestor.is_symlink():
            raise FlurryError(f"Workspace root traverses a symlink: {ancestor}")
        if not ancestor.is_dir():
            raise FlurryError(f"Workspace root is not a directory: {ancestor}")
    path = Path(relative)
    if not relative or path.is_absolute() or any(part in {"", ".", ".."} for part in relative.split("/")):
        raise FlurryError(f"Clone destination must be a non-escaping relative path: {relative!r}")
    current = root
    for part in path.parts:
        current = current / part
        if current.is_symlink():
            raise FlurryError(f"Clone destination traverses a symlink: {current}")
        if current != root / path and current.exists() and not current.is_dir():
            raise FlurryError(f"Clone destination parent is not a directory: {current}")
    return root / path


def _publish(source: Path, destination: Path) -> None:
    # POSIX rename alone may overwrite an existing empty directory.
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "darwin":
        rename = getattr(libc, "renamex_np", None)
        if rename is None:
            raise FlurryError("Safe clone publication requires renamex_np(RENAME_EXCL) on macOS")
        rename_excl = 4
        result = rename(os.fsencode(source), os.fsencode(destination), rename_excl)
    else:
        rename = getattr(libc, "renameat2", None)
        if rename is None:
            raise FlurryError("Safe clone publication requires renameat2(RENAME_NOREPLACE) on this platform")
        at_fdcwd = -100
        rename_noreplace = 1
        result = rename(at_fdcwd, os.fsencode(source), at_fdcwd, os.fsencode(destination), rename_noreplace)
    if result:
        code = ctypes.get_errno()
        if code == errno.EEXIST:
            raise FlurryError(f"Clone destination appeared during preparation; not overwritten: {destination}")
        raise FlurryError(f"Cannot publish clone without replacement: {os.strerror(code)}")


class Pull:
    def __init__(self, runner: Runner, nix: Nix, permissions: Permissions):
        self.runner = runner
        self.nix = nix
        self.permissions = permissions

    def _metadata(self, reference: str, require_lock: bool) -> dict[str, object]:
        args = ["nix", "--extra-experimental-features", "nix-command flakes", "flake", "metadata",
                "--json", "--no-write-lock-file", "--no-accept-flake-config", "--no-use-registries",
                "--option", "allow-import-from-derivation", "false"]
        if require_lock:
            args.append("--no-update-lock-file")
        raw = self.runner.run([*args, reference], None)
        if len(raw) > MAX_LOCK_BYTES:
            raise FlurryError("Flake metadata exceeds discovery byte limit; closure is incomplete")
        try:
            value = json.loads(raw)
        except (ValueError, UnicodeError) as error:
            raise FlurryError("Nix metadata is not valid JSON") from error
        if not isinstance(value, dict):
            raise FlurryError("Nix metadata is not an object")
        return value

    def _closure(self, lock: object, base: Path) -> tuple[list[Source], list[str], list[str]]:
        if not isinstance(lock, dict) or not isinstance(lock.get("nodes"), dict):
            raise FlurryError("Missing or invalid lock graph; closure is incomplete")
        nodes = lock["nodes"]
        if len(nodes) > MAX_LOCK_NODES:
            raise FlurryError(f"Lock graph exceeds {MAX_LOCK_NODES} nodes; closure is incomplete")
        root = lock.get("root")
        if not isinstance(root, str) or root not in nodes:
            raise FlurryError("Lock graph has no valid root")
        sources: list[Source] = []
        issues: list[str] = []
        skipped: list[str] = []
        visited: set[str] = set()
        active_aliases: set[tuple[str, ...]] = set()

        def resolve(edge: object) -> str:
            if isinstance(edge, str):
                if edge not in nodes:
                    raise FlurryError(f"Unresolved lock node {edge!r}")
                return edge
            if not isinstance(edge, list) or not all(isinstance(part, str) for part in edge):
                raise FlurryError("Invalid lock follows path")
            key = tuple(edge)
            if key in active_aliases:
                raise FlurryError(f"Cyclic lock follows path: {'/'.join(key)}")
            active_aliases.add(key)
            try:
                current = root
                for part in edge:
                    node = nodes[current]
                    if not isinstance(node, dict) or not isinstance(node.get("inputs"), dict) or part not in node["inputs"]:
                        raise FlurryError(f"Unresolved lock follows path: {'/'.join(key)}")
                    current = resolve(node["inputs"][part])
                return current
            finally:
                active_aliases.remove(key)

        pending = [root]
        while pending:
            node_id = pending.pop()
            if node_id in visited:
                continue
            visited.add(node_id)
            node = nodes[node_id]
            if not isinstance(node, dict):
                issues.append(f"Invalid lock node {node_id}")
                continue
            if node_id != root:
                locked = node.get("locked")
                original = node.get("original")
                source = parse_source(locked, base) if isinstance(locked, dict) else None
                declared = parse_source(original, base) if isinstance(original, dict) else None
                if source is None or source.clone_url is None:
                    if isinstance(locked, dict) and locked.get("type") in {"path", "tarball", "file", "mercurial"}:
                        skipped.append(f"Non-Git source skipped at lock node {node_id} ({locked['type']}); its metadata edges were traversed")
                    else:
                        issues.append(f"Unsupported or unresolved source at lock node {node_id}")
                elif declared is not None and declared.repository_id != source.repository_id:
                    issues.append(f"Declared and locked repository identities differ at lock node {node_id}")
                else:
                    source = replace(source, ref=declared.ref if declared is not None else None,
                                     flake=node.get("flake") is not False)
                    sources.append(source)
            edges = node.get("inputs", {})
            if not isinstance(edges, dict):
                issues.append(f"Invalid inputs at lock node {node_id}")
                continue
            for edge in edges.values():
                try:
                    pending.append(resolve(edge))
                except FlurryError as error:
                    issues.append(str(error))
        return sources, issues, skipped

    def _identity(self, path: Path) -> str:
        if not path.is_dir() or not (path / ".git").exists():
            raise FlurryError(f"Destination exists but is not a Git checkout: {path}")
        actual = self.runner.git_text(path, "rev-parse", "--show-toplevel")
        if Path(actual).resolve() != path.resolve():
            raise FlurryError(f"Destination is not a checkout root: {path}")
        remote = self.runner.git_text(path, "remote", "get-url", "origin")
        source = parse_source(remote, path)
        if source is None:
            raise FlurryError(f"Destination origin has unsupported identity: {path}")
        return source.repository_id

    def _branch(self, source: Source) -> str:
        raw = self.runner.text(["git", "-c", "submodule.recurse=false", "ls-remote", "--symref",
                                "--", source.clone_url, "HEAD", "refs/heads/*", "refs/tags/*"], None)
        refs: set[str] = set()
        default = None
        for line in raw.splitlines():
            if line.startswith("ref: refs/heads/") and line.endswith("\tHEAD"):
                default = line.split("\t", 1)[0][len("ref: refs/heads/"):]
            elif "\t" in line:
                refs.add(line.split("\t", 1)[1])
        requested = source.ref
        if requested is None or re.fullmatch(r"[0-9a-fA-F]{40}|[0-9a-fA-F]{64}", requested):
            selected = default
        elif requested.startswith("refs/heads/"):
            selected = requested[len("refs/heads/"):] if requested in refs else None
        elif requested.startswith("refs/tags/"):
            selected = default if requested in refs else None
        else:
            head = f"refs/heads/{requested}" in refs
            tag = f"refs/tags/{requested}" in refs
            if head and tag:
                raise FlurryError(f"Ambiguous branch/tag ref {requested!r}; specify refs/heads/ or refs/tags/")
            selected = requested if head else default if tag else None
        if not selected:
            raise FlurryError("Cannot resolve requested ref or remote default branch for editable tip checkout")
        return selected

    def plan(self, root_ref: str, root: Path, excludes: tuple[str, ...],
             paths: Mapping[str, str]) -> PullPlan:
        root = root.resolve(strict=True)
        issues: list[str] = []
        warnings = ["Discovery follows the locked dependency closure, not the newly cloned branch-tip closure; no locks are rewritten",
                    "Requires exclusive access to a trusted workspace; path checks do not prevent concurrent ancestor replacement during Git execution"]
        candidate = Path(root_ref)
        if not candidate.is_absolute():
            candidate = root / candidate
        local = candidate.is_dir() and (candidate / "flake.nix").is_file()
        reference = str(candidate.resolve()) if local else root_ref
        provenance = "existing lock validated by Nix metadata" if local and (candidate / "flake.lock").is_file() else "Nix metadata resolved lock graph"
        try:
            if local:
                for name in ("flake.nix", "flake.lock"):
                    if (candidate / name).is_symlink():
                        raise FlurryError(f"Refusing symlink flake metadata: {candidate / name}")
            if not local and parse_source(root_ref, root) is None and ":" not in root_ref:
                raise FlurryError("Unknown root name; use an existing local flake or an explicit source reference")
            metadata = self._metadata(reference, local and (candidate / "flake.lock").is_file())
            sources, closure_issues, skipped = self._closure(metadata.get("locks"), candidate if local else root)
            issues.extend(closure_issues)
            warnings.extend(skipped)
            if not local:
                original = metadata.get("original")
                source = parse_source(original if isinstance(original, dict) else root_ref, root)
                if source is None or source.clone_url is None:
                    if isinstance(original, dict) and original.get("type") in {"path", "tarball", "file", "mercurial"}:
                        warnings.append("Non-Git root not materialized; its metadata edges were traversed")
                    else:
                        issues.append("Root reference has no supported Git repository identity")
                else:
                    sources.insert(0, source)
        except (FlurryError, OSError, ValueError, RecursionError) as error:
            return PullPlan(root_ref, str(root), provenance, (), (str(error),), tuple(warnings))

        grouped: dict[str, list[Source]] = {}
        for source in sources:
            grouped.setdefault(source.repository_id, []).append(source)
        normalized_paths: dict[str, str] = {}
        for key, relative in paths.items():
            try:
                mapped = None if key in grouped else parse_source(key, root)
                identity = key if mapped is None else mapped.repository_id
                if identity not in grouped:
                    warnings.append(f"Path mapping matched no reachable Git repository: {key}")
                    continue
                if identity in normalized_paths and normalized_paths[identity] != relative:
                    issues.append(f"Conflicting path mappings for {identity}")
                else:
                    normalized_paths[identity] = relative
            except FlurryError as error:
                issues.append(f"Invalid path mapping identity: {error}")
        entries: list[PullEntry] = []
        destinations: dict[str, str] = {}
        matched_excludes: set[str] = set()
        for identity, group in sorted(grouped.items()):
            source = group[0]
            basename = source.project.rsplit("/", 1)[-1] if source.project is not None else identity.rsplit("/", 1)[-1].removesuffix(".git")
            relative = normalized_paths.get(identity, basename)
            entry = PullEntry(identity, source.url, source.clone_url, str(root / relative),
                              tuple(sorted({item.url for item in group})),
                              tuple(sorted({item.rev for item in group if item.rev is not None})),
                              None, "blocked", None, "")
            try:
                destination = _destination(root, relative)
                entry = replace(entry, destination=str(destination))
                matching = {pattern for pattern in excludes if fnmatch.fnmatchcase(relative, pattern)}
                matched_excludes.update(matching)
                if matching:
                    entries.append(replace(entry, action="excluded", reason="Destination excluded; metadata traversal was retained"))
                    continue
                if str(destination) in destinations and destinations[str(destination)] != identity:
                    raise FlurryError("Multiple repository identities map to one destination; configure distinct paths")
                destinations[str(destination)] = identity
                permission = self.permissions.check(source)
                entry = replace(entry, permission=permission)
                if permission.state is PermissionState.UNKNOWN:
                    raise FlurryError(permission.reason)
                if destination.exists():
                    if self._identity(destination) != identity:
                        raise FlurryError("Destination repository identity differs; configure an explicit path mapping")
                    entries.append(replace(entry, action="reuse", reason="Matching checkout retained without fetching or branch changes"))
                elif permission.state is PermissionState.READ_ONLY:
                    entries.append(replace(entry, action="read-only", reason=permission.reason))
                else:
                    if not destination.parent.is_dir():
                        raise FlurryError(f"Destination parent must already exist: {destination.parent}")
                    branches = {self._branch(item) for item in group}
                    if len(branches) != 1:
                        raise FlurryError("Conflicting branch demands for the same repository; an explicit ref selection is required")
                    entries.append(replace(entry, action="clone", branch=branches.pop(),
                                           reason="Clone editable branch tip; locked revisions may differ"))
            except (FlurryError, OSError, ValueError) as error:
                entries.append(replace(entry, reason=str(error)))
        # A collision invalidates both plans, including ancestor/descendant paths.
        collisions: set[str] = set()
        for index, entry in enumerate(entries):
            for other in entries[index + 1:]:
                first, second = Path(entry.destination), Path(other.destination)
                if first == second or first in second.parents or second in first.parents:
                    collisions.update((entry.destination, other.destination))
        entries = [replace(entry, action="blocked", reason="Repository destinations overlap; configure distinct paths")
                   if entry.destination in collisions and entry.action != "excluded" else entry for entry in entries]
        warnings.extend(f"Exclusion matched no destination: {pattern}" for pattern in excludes if pattern not in matched_excludes)
        return PullPlan(root_ref, str(root), provenance, tuple(entries), tuple(issues), tuple(warnings))

    def apply(self, plan: PullPlan) -> tuple[PullResult, ...]:
        if not plan.complete:
            raise FlurryError("Pull plan is incomplete or blocked; no clones were started")
        root = Path(plan.root)
        for entry in plan.entries:
            destination = _destination(root, os.fspath(Path(entry.destination).relative_to(root)))
            if entry.action == "clone":
                if entry.branch is None:
                    raise FlurryError("Clone plan has no selected branch")
                if destination.exists():
                    raise FlurryError(f"Destination appeared since planning; replan without overwriting: {destination}")
                if not destination.parent.is_dir():
                    raise FlurryError(f"Destination parent must already exist: {destination.parent}")
            elif entry.action == "reuse" and self._identity(destination) != entry.repository_id:
                raise FlurryError(f"Existing checkout changed identity since planning: {destination}")
        results: list[PullResult] = []
        for entry in plan.entries:
            destination = _destination(root, os.fspath(Path(entry.destination).relative_to(root)))
            if entry.action == "reuse":
                if self._identity(destination) != entry.repository_id:
                    raise FlurryError(f"Existing checkout changed identity since planning: {destination}")
                results.append(PullResult(entry.repository_id, str(destination), "reused", None, entry.reason))
                continue
            if entry.action != "clone":
                results.append(PullResult(entry.repository_id, str(destination), entry.action, None, entry.reason))
                continue
            if entry.branch is None:
                raise FlurryError("Clone plan has no selected branch")
            if destination.exists():
                raise FlurryError(f"Destination appeared since planning; replan without overwriting: {destination}")
            if not destination.parent.is_dir():
                raise FlurryError(f"Destination parent must already exist: {destination.parent}")
            staging = Path(tempfile.mkdtemp(prefix=".flurry-pull-", dir=destination.parent))
            clone = staging / "checkout"
            try:
                self.runner.run(["git", "-c", "submodule.recurse=false", "-c", "core.hooksPath=/dev/null",
                                 "clone", "--no-recurse-submodules", "--branch", entry.branch,
                                 "--", entry.clone_url, str(clone)], None)
                if self._identity(clone) != entry.repository_id:
                    raise FlurryError("Prepared clone identity does not match the plan")
                branch = self.runner.git_text(clone, "symbolic-ref", "HEAD")
                if branch != f"refs/heads/{entry.branch}":
                    raise FlurryError("Prepared clone is not on the planned editable branch")
                revision = self.runner.git_text(clone, "rev-parse", "HEAD")
                _destination(root, os.fspath(destination.relative_to(root)))
                _publish(clone, destination)
                results.append(PullResult(entry.repository_id, str(destination), "cloned", revision,
                                          "Editable tip cloned; locked closure does not imply branch-tip closure"))
            except (FlurryError, OSError) as error:
                raise FlurryError(f"Pull stopped after {len(results)} completed entries; partial clone retained at {staging}: {error}") from error
            else:
                shutil.rmtree(staging)
        return tuple(results)
