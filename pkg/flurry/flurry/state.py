from __future__ import annotations

import fcntl
import hashlib
import json
import os
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator

from .process import FlurryError, Runner


STATE_DIRECTORY = ".flurry"
JOURNAL_VERSION = 1


def private_directory(path: Path) -> None:
    if path.is_symlink():
        raise FlurryError(f"Refusing symlink state directory: {path}")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not path.is_dir() or path.stat().st_uid != os.getuid():
        raise FlurryError(f"State directory is not owned by the current user: {path}")
    path.chmod(0o700)


@contextmanager
def workspace_lock(root: Path) -> Iterator[None]:
    directory = root / STATE_DIRECTORY
    private_directory(directory)
    descriptor = os.open(directory / "workspace.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise FlurryError(f"Another flurry operation holds {directory / 'workspace.lock'}") from error
        yield
    finally:
        os.close(descriptor)


def fingerprint(repo: Path, runner: Runner) -> str:
    digest = hashlib.sha256()
    commands = (
        ("rev-parse", "HEAD"),
        ("symbolic-ref", "HEAD"),
        ("diff", "--cached", "--binary", "--no-ext-diff", "--no-textconv"),
        ("diff", "--binary", "--no-ext-diff", "--no-textconv"),
        ("stash", "list", "--format=%H"),
        ("ls-files", "-v", "-z"),
        ("config", "--local", "--null", "--list"),
    )
    for args in commands:
        value = runner.git(repo, *args)
        digest.update(len(value).to_bytes(8, "big"))
        digest.update(value)
    for item in runner.git(repo, "ls-files", "--others", "--exclude-standard", "-z").split(b"\0"):
        if not item:
            continue
        path = repo / os.fsdecode(item)
        if path.is_symlink():
            kind = b"symlink"
            data = os.fsencode(os.readlink(path))
        elif path.is_file():
            kind = b"executable" if path.stat().st_mode & 0o111 else b"file"
            data = path.read_bytes()
        else:
            raise FlurryError(f"Unsupported untracked file: {path}")
        digest.update(item + b"\0" + kind + b"\0" + len(data).to_bytes(8, "big") + data)
    return digest.hexdigest()


def config_digest(root: Path) -> str:
    digest = hashlib.sha256()
    for name in ("flurry.toml", "flurry.local.toml"):
        path = root / name
        digest.update(name.encode())
        digest.update(path.read_bytes() if path.exists() else b"<absent>")
    return digest.hexdigest()


class Journal:
    def __init__(self, root: Path, options: dict[str, object]):
        self.root = root
        self.run_id = uuid.uuid4().hex
        runs = root / STATE_DIRECTORY / "runs"
        private_directory(runs)
        self.directory = runs / self.run_id
        private_directory(self.directory)
        self.path = self.directory / "run.json"
        self.document: dict[str, object] = {
            "version": JOURNAL_VERSION,
            "id": self.run_id,
            "root": os.fspath(root),
            "created": datetime.now(timezone.utc).isoformat(),
            "config_digest": config_digest(root),
            "options": options,
            "status": "running",
            "action": "preflight",
            "repositories": {},
        }
        self.save()

    def save(self) -> None:
        data = json.dumps(self.document, indent=2, sort_keys=True).encode() + b"\n"
        temporary = self.directory / "run.json.new"
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            with os.fdopen(descriptor, "wb") as output:
                output.write(data)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, self.path)
            parent = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(parent)
            finally:
                os.close(parent)
        finally:
            if temporary.exists():
                temporary.unlink()

    def action(self, name: str) -> None:
        self.document["action"] = name
        self.save()

    def repository(self, name: str, fields: dict[str, object]) -> None:
        repositories = self.document["repositories"]
        if not isinstance(repositories, dict):
            raise FlurryError("Invalid in-memory run journal")
        previous = repositories.get(name, {})
        if not isinstance(previous, dict):
            raise FlurryError("Invalid in-memory repository journal")
        repositories[name] = previous | fields
        self.save()

    def finish(self, status: str, detail: str) -> None:
        self.document["status"] = status
        self.document["detail"] = detail
        self.save()


def load_journal(root: Path, run_id: str) -> dict[str, object]:
    if not run_id or any(character not in "0123456789abcdef" for character in run_id):
        raise FlurryError("Invalid run ID")
    path = root / STATE_DIRECTORY / "runs" / run_id / "run.json"
    if path.is_symlink() or path.parent.is_symlink():
        raise FlurryError("Refusing symlink run journal")
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        raise FlurryError(f"Cannot read run {run_id}: {error}") from error
    if not isinstance(data, dict) or data.get("version") != JOURNAL_VERSION or data.get("root") != os.fspath(root):
        raise FlurryError("Run journal version/workspace mismatch")
    return data
