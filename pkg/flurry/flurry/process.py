from __future__ import annotations

import os
import re
import signal
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping, Sequence


class FlurryError(Exception):
    pass


def redact(text: str) -> str:
    return re.sub(r"(https?://)[^\s/@]+@", r"\1[redacted]@", text)


@dataclass(frozen=True)
class Result:
    stdout: bytes
    stderr: bytes
    returncode: int


class Runner:
    def __init__(self, environment: Mapping[str, str], timeout: float):
        self.environment = dict(environment)
        routing = {
            "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE",
            "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
            "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "GIT_NAMESPACE",
        }
        conflicts = sorted(key for key in routing if self.environment.get(key))
        if conflicts:
            raise FlurryError("Unset ambient Git routing/config overrides: " + ", ".join(conflicts))
        self.timeout = timeout

    def call(
        self,
        args: Sequence[str],
        cwd: Path | None,
        input_data: bytes | None,
        extra_env: Mapping[str, str],
        check: bool,
    ) -> Result:
        env = self.environment | dict(extra_env) | {"GIT_TERMINAL_PROMPT": "0"}
        try:
            process = subprocess.Popen(
                list(args), cwd=cwd, env=env, stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
            )
        except OSError as error:
            raise FlurryError(redact(f"Cannot execute {args[0]}: {error}")) from error
        try:
            stdout, stderr = process.communicate(input_data, timeout=self.timeout)
        except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate()
            if isinstance(error, KeyboardInterrupt):
                raise
            raise FlurryError(f"Cannot execute {args[0]}: timed out after {self.timeout} seconds; process group stopped") from error
        result = Result(stdout, stderr, process.returncode)
        if check and result.returncode:
            detail = result.stderr.decode(errors="replace").strip()
            raise FlurryError(redact(f"{args[0]} failed ({result.returncode}): {detail}"))
        return result

    def run(self, args: Sequence[str], cwd: Path | None) -> bytes:
        return self.call(args, cwd, None, {}, True).stdout

    def text(self, args: Sequence[str], cwd: Path | None) -> str:
        return self.run(args, cwd).decode(errors="surrogateescape").strip()

    def git_path(self, repo: Path, *args: str) -> Path:
        # Native configuration matters when resolving source core.hooksPath.
        data = self.run(["git", "-C", os.fspath(repo), "rev-parse", *args], None)
        if not data.endswith(b"\n"):
            raise FlurryError(f"Invalid Git path response: {repo}")
        path = Path(os.fsdecode(data[:-1]))
        # --path-format=absolute canonicalizes leaf symlinks, hiding unsafe metadata writes.
        return path if path.is_absolute() else repo.absolute() / path

    def git(self, repo: Path, *args: str) -> bytes:
        return self.run([
            "git", "-C", os.fspath(repo), "-c", "submodule.recurse=false",
            "-c", "core.hooksPath=/dev/null", *args,
        ], None)

    def git_text(self, repo: Path, *args: str) -> str:
        return self.git(repo, *args).decode(errors="surrogateescape").strip()


def remote_head(runner: Runner, repo: Path, url: str, ref: str) -> str | None:
    exact_ref = os.fsencode(ref)
    head = None
    for row in runner.git(repo, "ls-remote", "--refs", "--", url, ref).splitlines(keepends=True):
        match = re.fullmatch(rb"([0-9a-f]{40}|[0-9a-f]{64})\t(refs/[^\x00-\x20\x7f]+)\n", row)
        if match is None or not match[1].strip(b"0"):
            raise FlurryError("Malformed/ambiguous remote ref response")
        if match[2] == exact_ref:
            if head is not None:
                raise FlurryError("Malformed/ambiguous remote ref response")
            head = match[1].decode("ascii")
        elif not match[2].endswith(b"/" + exact_ref):
            raise FlurryError("Malformed/ambiguous remote ref response")
    return head
