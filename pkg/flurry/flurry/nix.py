from __future__ import annotations

import json
import shlex
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path

from .process import FlurryError, Runner, redact
from .source import Source, parse_source


@dataclass(frozen=True)
class Input:
    name: str
    source: Source | None
    follows: str | None


class Nix:
    def __init__(self, runner: Runner):
        self.runner = runner

    def _preflight(self, path: Path) -> Path:
        root = path.resolve()
        if not root.is_dir():
            raise FlurryError(f"Flake root is not a directory: {path}")
        for name in ("flake.nix", "flake.lock"):
            candidate = root / name
            if candidate.is_symlink():
                raise FlurryError(f"Refusing symlink flake boundary: {candidate}")
        return root

    def _argv(self, arguments: Sequence[str]) -> list[str]:
        return [
            "nix", "--extra-experimental-features", "nix-command flakes",
            "--option", "accept-flake-config", "false",
            "--option", "allow-import-from-derivation", "false", *arguments,
        ]

    def _command(self, arguments: Sequence[str], path: Path) -> bytes:
        return self.runner.run(self._argv(arguments), path)

    def inputs(self, path: Path, *, base: Path | None = None) -> tuple[Input, ...]:
        path = self._preflight(path)
        declaration = path / "flake.nix"
        if not declaration.is_file():
            raise FlurryError(f"No flake declaration: {declaration}")
        expression = 'flake: builtins.mapAttrs (_: input: if builtins.isAttrs input then builtins.removeAttrs input [ "inputs" ] else input) (flake.inputs or {})'
        data = self._command([
            "eval", "--offline", "--json", "--file", str(declaration),
            "--apply", expression,
        ], path)
        try:
            values = json.loads(data)
        except (ValueError, UnicodeError) as error:
            raise FlurryError(f"Invalid Nix declaration JSON in {path}") from error
        if not isinstance(values, dict):
            raise FlurryError(f"Flake inputs must be an attribute set: {path}")
        inputs: list[Input] = []
        for name, value in sorted(values.items()):
            if not isinstance(name, str) or not name or name.startswith("-") or any(ord(c) < 32 for c in name):
                raise FlurryError("Invalid flake input name")
            if isinstance(value, dict) and "follows" in value:
                follows = value["follows"]
                if not isinstance(follows, str) or any(not part or part in (".", "..") for part in follows.split("/")) and follows != "":
                    raise FlurryError(f"Invalid follows path for {name}")
                inputs.append(Input(name, None, follows))
            elif isinstance(value, (dict, str)):
                inputs.append(Input(name, parse_source(value, path if base is None else base), None))
            else:
                raise FlurryError(f"Invalid source declaration for {name}")
        return tuple(inputs)

    def update(self, path: Path, names: Sequence[str]) -> None:
        path = self._preflight(path)
        if not names:
            return
        if any(not name or name.startswith("-") or any(ord(c) < 32 for c in name) for name in names):
            raise FlurryError("Invalid targeted input name")
        self._command(["flake", "update", "--refresh", *names], path)

    def check(self, path: Path, full: bool, *, report: Callable[[str], None]) -> None:
        path = self._preflight(path)
        arguments = ["flake", "check", "--no-write-lock-file"]
        if not full:
            arguments.append("--no-build")
        argv = self._argv(arguments)
        command = redact(f"cd {shlex.quote(str(path))} && {shlex.join(argv)}")
        report(f"Checking: {command}")
        try:
            self.runner.run(argv, path)
        except FlurryError as error:
            raise FlurryError(redact(f"Nix check failed: {command}\n{error}")) from error

    def locked_inputs(self, path: Path) -> Mapping[str, Source]:
        path = self._preflight(path)
        lock_path = path / "flake.lock"
        try:
            lock = json.loads(lock_path.read_text())
        except (OSError, ValueError) as error:
            raise FlurryError(f"Cannot read lock graph: {lock_path}: {error}") from error
        if not isinstance(lock, dict) or not isinstance(lock.get("nodes"), dict) or not isinstance(lock.get("root"), str):
            raise FlurryError(f"Malformed lock graph: {lock_path}")
        nodes = lock["nodes"]
        root = lock["root"]

        def node(key: str) -> dict[str, object]:
            value = nodes.get(key)
            if not isinstance(value, dict):
                raise FlurryError(f"Missing lock node: {key}")
            return value

        def inputs(key: str) -> dict[str, object]:
            value = node(key).get("inputs", {})
            if not isinstance(value, dict):
                raise FlurryError(f"Malformed lock node inputs: {key}")
            return value

        def resolve(reference: object, visiting: frozenset[tuple[str, ...]]) -> str:
            if isinstance(reference, str):
                node(reference)
                return reference
            if not isinstance(reference, list) or not all(isinstance(part, str) and part for part in reference):
                raise FlurryError("Malformed lock follows reference")
            key = tuple(reference)
            if key in visiting:
                raise FlurryError("Cycle in lock follows: " + "/".join(key))
            current = root
            for part in reference:
                children = inputs(current)
                if part not in children:
                    raise FlurryError("Unresolved lock follows: " + "/".join(key))
                current = resolve(children[part], visiting | {key})
            return current

        result: dict[str, Source] = {}
        for name, reference in sorted(inputs(root).items()):
            target = node(resolve(reference, frozenset()))
            locked = target.get("locked")
            if locked is None and target is node(root):
                continue
            if not isinstance(locked, dict):
                raise FlurryError(f"Lock node for {name} has no locked source")
            source = parse_source(locked | {"flake": target.get("flake", True)}, path)
            if source is not None:
                result[name] = source
        return result
