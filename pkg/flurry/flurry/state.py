from __future__ import annotations

import fcntl
import hashlib
import json
import os
import stat
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


def ignore_state_directory(root: Path, runner: Runner) -> None:
    result = runner.call(["git", "-C", os.fspath(root), "rev-parse", "--is-inside-work-tree"],
                         None, None, {"LC_ALL": "C"}, False)
    if result.returncode == 128 and result.stderr.startswith(b"fatal: not a git repository"):
        return
    if result.returncode or result.stdout not in (b"true\n", b"false\n"):
        raise FlurryError(f"Cannot determine Git workspace for private state: {root}")
    if result.stdout == b"false\n":
        return
    top = runner.git_path(root, "--show-toplevel")
    relative = (root.resolve().relative_to(top) / STATE_DIRECTORY).as_posix()
    if runner.git(root, "ls-files", "-z", "--", f":(top,literal){relative}"):
        raise FlurryError(f"Flurry state is already tracked; untrack it explicitly before continuing: {root / STATE_DIRECTORY}")
    if "\n" in relative or "\r" in relative:
        raise FlurryError("Cannot encode a workspace with line breaks in Git exclude rules")
    literal = "".join("\\" + character if character in "\\*?[]" else character for character in relative)
    rule = os.fsencode("/" + literal + "/")
    target = os.fspath(root / STATE_DIRECTORY) + "/"

    def ignored() -> bool:
        check = runner.call(["git", "-C", os.fspath(root), "check-ignore", "--quiet", "--no-index", "--", target],
                            None, None, {}, False)
        if check.returncode not in (0, 1):
            raise FlurryError(f"Cannot inspect Git exclusion for private state: {target}")
        return check.returncode == 0

    if ignored():
        return
    exclude = runner.git_path(root, "--git-path", "info/exclude")
    try:
        if exclude.parent.is_symlink():
            raise FlurryError(f"Refusing symlink Git exclude directory: {exclude.parent}")
        exclude.parent.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(exclude, os.O_RDWR | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o666)
        with os.fdopen(descriptor, "r+b") as output:
            if not stat.S_ISREG(os.fstat(output.fileno()).st_mode):
                raise FlurryError(f"Git exclude path is not a regular file: {exclude}")
            fcntl.flock(output.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            data = output.read()
            if data.rstrip(b"\r\n").split(b"\n")[-1] != rule:
                output.write((b"\n" if data and not data.endswith(b"\n") else b"") + rule + b"\n")
                output.flush()
                os.fsync(output.fileno())
    except OSError as error:
        raise FlurryError(f"Cannot update Git exclusion for private state: {exclude}: {error}") from error
    if not ignored():
        raise FlurryError(f"Flurry state is not ignored; reconcile overriding .gitignore rules: {target}")


@contextmanager
def workspace_lock(root: Path, runner: Runner) -> Iterator[None]:
    directory = root / STATE_DIRECTORY
    private_directory(directory)
    descriptor = os.open(directory / "workspace.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise FlurryError(f"Another flurry operation holds {directory / 'workspace.lock'}") from error
        ignore_state_directory(root, runner)
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
