from __future__ import annotations

import fnmatch
import json
import os
import tomllib
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

from .nix import Input, Nix
from .process import FlurryError, Runner
from .source import Source, parse_source


@dataclass(frozen=True)
class RepoSettings:
    name: str
    path: Path
    rebase_onto: str | None = None
    push_remote: str | None = None
    push_ref: str | None = None
    source: Source | None = None


@dataclass(frozen=True)
class Config:
    root: Path
    excludes: tuple[str, ...]
    repositories: tuple[RepoSettings, ...]
    gitlab_hosts: tuple[str, ...]


@dataclass(frozen=True)
class Repository:
    name: str
    path: Path
    common_dir: Path
    branch: str | None
    head: str
    origin: str | None
    upstream: str | None
    excluded: bool
    settings: RepoSettings


@dataclass(frozen=True)
class Edge:
    consumer: Repository
    provider: Repository
    input: Input


@dataclass(frozen=True)
class WorkspaceGraph:
    order: tuple[Repository, ...]
    edges: tuple[Edge, ...]


def _value(value: object, label: str) -> str:
    if not isinstance(value, str) or not value or value.startswith("-") or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise FlurryError(f"Invalid {label}")
    return value


def _exclude(value: object) -> str:
    pattern = _value(value, "exclusion pattern")
    if PurePosixPath(pattern).is_absolute() or any(part in ("", ".", "..") for part in pattern.split("/")) or "\\" in pattern:
        raise FlurryError("Exclusion patterns must be normalized workspace-relative paths")
    return pattern


def _table(path: Path) -> dict[str, object]:
    if not path.exists() and not path.is_symlink():
        return {}
    try:
        with path.open("rb") as handle:
            data = tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError) as error:
        raise FlurryError(f"Cannot read configuration {path}: {error}") from error
    allowed = {"version", "exclude", "repositories", "gitlab_hosts"}
    if set(data) - allowed:
        raise FlurryError(f"Unknown configuration keys in {path}: {', '.join(sorted(set(data) - allowed))}")
    if "version" in data and (type(data["version"]) is not int or data["version"] != 1):
        raise FlurryError(f"Unsupported configuration version in {path}")
    for key in ("exclude", "gitlab_hosts"):
        if key in data and (not isinstance(data[key], list) or not all(isinstance(item, str) for item in data[key])):
            raise FlurryError(f"{key} must be an array of strings in {path}")
    repositories = data.get("repositories", {})
    if not isinstance(repositories, dict):
        raise FlurryError(f"repositories must be a table in {path}")
    for name, settings in repositories.items():
        _value(name, "repository name")
        if not isinstance(settings, dict) or set(settings) - {"path", "rebase_onto", "push_remote", "push_ref", "source"}:
            raise FlurryError(f"Unknown or malformed repository settings: {name}")
        for key, value in settings.items():
            if key == "source":
                if not isinstance(value, (dict, str)):
                    raise FlurryError(f"Invalid configured source: {name}")
            else:
                _value(value, f"{name}.{key}")
    return data


def init_config(root: Path, excludes: tuple[str, ...]) -> Path:
    root = root.resolve()
    if not root.is_dir():
        raise FlurryError(f"Workspace root is not a directory: {root}")
    patterns = list(dict.fromkeys(_exclude(value) for value in excludes))
    document = (
        "version = 1\n"
        f"exclude = {json.dumps(patterns, ensure_ascii=False)}\n"
        "gitlab_hosts = []\n"
        "\n"
        "# Put machine-local repository overrides in flurry.local.toml.\n"
        "# Exclusions from both files and --exclude flags are additive.\n"
    )
    content = document.encode("utf-8")
    tomllib.loads(document)
    path = root / "flurry.toml"
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except FileExistsError as error:
        raise FlurryError(f"Refusing to overwrite existing configuration: {path}") from error
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
    except OSError as error:
        raise FlurryError(f"Cannot finish writing configuration {path}: {error}; an incomplete file may remain, inspect it before retrying") from error
    return path


def load_config(root: Path, extra_excludes: tuple[str, ...]) -> Config:
    root = root.resolve()
    if not root.is_dir():
        raise FlurryError(f"Workspace root is not a directory: {root}")
    base = _table(root / "flurry.toml")
    local = _table(root / "flurry.local.toml")
    excludes = tuple(dict.fromkeys(_exclude(value) for value in (*base.get("exclude", []), *local.get("exclude", []), *extra_excludes)))
    repositories: dict[str, dict[str, object]] = {}
    for table in (base, local):
        for name, settings in table.get("repositories", {}).items():
            repositories[name] = repositories.get(name, {}) | settings
    configured: list[RepoSettings] = []
    paths: dict[Path, str] = {}
    for name, settings in sorted(repositories.items()):
        path = (root / settings.get("path", name)).resolve()
        if not path.is_relative_to(root) or path == root:
            raise FlurryError(f"Configured repository path escapes workspace children: {name}")
        if path in paths:
            raise FlurryError(f"Configured repository aliases collide: {paths[path]}, {name}")
        paths[path] = name
        source = parse_source(settings["source"], root) if "source" in settings else None
        if "source" in settings and source is None:
            raise FlurryError(f"Configured repository source is not supported Git: {name}")
        configured.append(RepoSettings(name, path, settings.get("rebase_onto"), settings.get("push_remote"), settings.get("push_ref"), source))
    hosts: list[str] = []
    for value in local.get("gitlab_hosts", base.get("gitlab_hosts", [])):
        source = parse_source({"type": "gitlab", "owner": "validation", "repo": "validation", "host": value}, root)
        hosts.append(source.host)
    return Config(root, excludes, tuple(configured), tuple(dict.fromkeys(hosts)))


def _optional(runner: Runner, path: Path, *arguments: str) -> str | None:
    result = runner.call(["git", "-C", str(path), "-c", "submodule.recurse=false", *arguments], None, None, {}, False)
    if result.returncode:
        return None
    return result.stdout.decode(errors="surrogateescape").strip() or None


def discover(config: Config, runner: Runner) -> tuple[Repository, ...]:
    configured = {settings.path.resolve(): settings for settings in config.repositories}
    candidates: dict[Path, RepoSettings] = dict(configured)
    for child in sorted(config.root.iterdir()):
        if child.is_dir() and (child / ".git").exists():
            path = child.resolve()
            if not path.is_relative_to(config.root) or path == config.root:
                raise FlurryError(f"Repository alias escapes workspace: {child}")
            if path not in candidates:
                candidates[path] = RepoSettings(path.relative_to(config.root).as_posix(), path)
    examined: set[Path] = set()
    pending = list(candidates)
    while pending:
        path = pending.pop(0)
        if path in examined:
            continue
        examined.add(path)
        if not (path / ".git").exists():
            raise FlurryError(f"Configured path is not an initialized Git checkout: {path}")
        if not (path / ".gitmodules").is_file():
            continue
        result = runner.call(["git", "config", "--null", "--file", str(path / ".gitmodules"), "--get-regexp", r"^submodule\..*\.path$"], None, None, {}, False)
        if result.returncode not in (0, 1):
            raise FlurryError(f"Cannot inspect submodules: {path}")
        for record in result.stdout.decode(errors="surrogateescape").split("\0"):
            if not record:
                continue
            _, separator, value = record.partition("\n")
            if not separator or not value:
                raise FlurryError(f"Malformed submodule path in {path}")
            relative = PurePosixPath(value)
            if relative.is_absolute() or ".." in relative.parts:
                raise FlurryError(f"Submodule path escapes repository: {value}")
            child = (path / value).resolve()
            if not child.is_relative_to(path):
                raise FlurryError(f"Submodule alias escapes repository: {value}")
            if (child / ".git").exists() and child not in candidates:
                try:
                    name = child.relative_to(config.root).as_posix()
                except ValueError:
                    name = candidates[path].name + "/" + value
                candidates[child] = RepoSettings(name, child)
                pending.append(child)
    found: list[Repository] = []
    all_repositories: list[Repository] = []
    matched_excludes: set[str] = set()
    for path, settings in sorted(candidates.items(), key=lambda pair: pair[1].name):
        top = Path(runner.git_text(path, "rev-parse", "--show-toplevel")).resolve()
        if top != path:
            raise FlurryError(f"Repository path is not a checkout root: {path}")
        common_dir = Path(runner.git_text(path, "rev-parse", "--path-format=absolute", "--git-common-dir")).resolve()
        branch = _optional(runner, path, "symbolic-ref", "--quiet", "--short", "HEAD")
        head = runner.git_text(path, "rev-parse", "--verify", "HEAD")
        origin = _optional(runner, path, "remote", "get-url", "origin")
        upstream = _optional(runner, path, "rev-parse", "--symbolic-full-name", "@{upstream}")
        relative = os.path.relpath(path, config.root).replace(os.sep, "/")
        matches = {pattern for pattern in config.excludes if fnmatch.fnmatchcase(relative, pattern)}
        matched_excludes.update(matches)
        repository = Repository(settings.name, path, common_dir, branch, head, origin, upstream, bool(matches), settings)
        all_repositories.append(repository)
        if path in configured or (path / "flake.nix").is_file():
            found.append(repository)
    identities: set[str] = set()
    if found:
        nix = Nix(runner)
        for repository in found:
            if not repository.excluded and (repository.path / "flake.nix").is_file():
                identities.update(item.source.repository_id for item in nix.inputs(repository.path) if item.source is not None)
    for repository in all_repositories:
        if repository in found or repository.origin is None:
            continue
        source = parse_source(repository.origin, repository.path)
        if source is not None and source.repository_id in identities:
            found.append(repository)
    unmatched = set(config.excludes) - matched_excludes
    if unmatched:
        raise FlurryError("Exclusion patterns matched no repository: " + ", ".join(sorted(unmatched)))
    return tuple(sorted(found, key=lambda repository: repository.name))


def provider_identities(repository: Repository) -> frozenset[str]:
    identities = {repository.settings.path.resolve().as_uri()}
    if repository.settings.source is not None:
        identities.add(repository.settings.source.repository_id)
    if repository.origin is not None:
        origin = parse_source(repository.origin, repository.settings.path)
        if origin is not None:
            identities.add(origin.repository_id)
    return frozenset(identities)


def build_graph(repositories: tuple[Repository, ...], nix: Nix) -> WorkspaceGraph:
    providers: dict[str, list[Repository]] = {}
    for repository in repositories:
        for identity in provider_identities(repository):
            providers.setdefault(identity, []).append(repository)
    edges: list[Edge] = []
    for consumer in repositories:
        if consumer.excluded or not (consumer.path / "flake.nix").is_file():
            continue
        for item in nix.inputs(consumer.path, base=consumer.settings.path):
            if item.source is None:
                continue
            choices = providers.get(item.source.repository_id, [])
            if not choices:
                continue
            if item.source.ref is not None and len(choices) > 1:
                branch = item.source.ref.removeprefix("refs/heads/")
                matching = [provider for provider in choices if provider.branch == branch]
                if len(matching) == 1:
                    choices = matching
            included = [provider for provider in choices if not provider.excluded]
            if len(included) == 1:
                choices = included
            if len(choices) != 1:
                raise FlurryError(f"Ambiguous providers for {consumer.name}/{item.name}: " + ", ".join(provider.name for provider in choices))
            provider = choices[0]
            if item.source.directory:
                raise FlurryError(f"Unsupported subflake dependency {consumer.name}/{item.name}: dir={item.source.directory}")
            if provider.common_dir == consumer.common_dir:
                raise FlurryError(f"Unsupported same-repository input: {consumer.name}/{item.name}")
            edges.append(Edge(consumer, provider, item))
    selected = tuple(repository for repository in repositories if not repository.excluded)
    dependencies = {repository: [] for repository in selected}
    for edge in edges:
        if not edge.provider.excluded and edge.input.source.rev is None:
            dependencies[edge.consumer].append(edge)
    order: list[Repository] = []
    visited: set[Repository] = set()
    visiting: list[Repository] = []
    trail: list[Edge] = []

    def visit(repository: Repository) -> None:
        if repository in visited:
            return
        if repository in visiting:
            start = visiting.index(repository)
            cycle = trail[start:]
            raise FlurryError("Mutable publication cycle: " + " -> ".join(f"{edge.consumer.name}/{edge.input.name} => {edge.provider.name}" for edge in cycle))
        visiting.append(repository)
        for edge in sorted(dependencies[repository], key=lambda edge: (edge.provider.name, edge.input.name)):
            trail.append(edge)
            visit(edge.provider)
            trail.pop()
        visiting.pop()
        visited.add(repository)
        order.append(repository)

    for repository in sorted(selected, key=lambda repository: repository.name):
        visit(repository)
    return WorkspaceGraph(tuple(order), tuple(edges))
