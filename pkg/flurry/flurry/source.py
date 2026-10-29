from __future__ import annotations

import re
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from urllib.parse import parse_qs, quote, unquote, urlencode, urlsplit, urlunsplit

from .process import FlurryError


@dataclass(frozen=True)
class Source:
    repository_id: str
    url: str
    clone_url: str | None
    host: str | None
    project: str | None
    ref: str | None
    rev: str | None
    directory: str
    flake: bool


def _text(value: object, label: str) -> str:
    if not isinstance(value, str) or not value or value.startswith("-") or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise FlurryError(f"Invalid {label}")
    return value


def _ref(value: object) -> str:
    ref = _text(value, "source ref")
    if any(c.isspace() for c in ref) or any(c in ref for c in "~^:?*[\\") or ".." in ref or "@{" in ref:
        raise FlurryError("Invalid source ref")
    return ref


def _user(value: str | None) -> str:
    if value is None:
        return ""
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]*", value):
        raise FlurryError("Invalid SSH username")
    return value + "@"


def _directory(value: object) -> str:
    if value in (None, ""):
        return ""
    text = _text(value, "source directory")
    path = PurePosixPath(text)
    if path.is_absolute() or ".." in path.parts or "\\" in text:
        raise FlurryError("Source directory must stay inside its repository")
    return path.as_posix() if path.as_posix() != "." else ""


def _host(value: object) -> str:
    host = _text(value, "source host").lower()
    if not re.fullmatch(r"[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?(?::[0-9]+)?", host):
        raise FlurryError("Invalid source host")
    return host


def _project(value: str) -> str:
    project = unquote(value).strip("/")
    if project.endswith(".git"):
        project = project[:-4]
    if not project or any(part in ("", ".", "..") or part.startswith("-") for part in project.split("/")) or any(c.isspace() for c in project) or any(c in project for c in "\\?#@:"):
        raise FlurryError("Invalid Git project path")
    _text(project, "Git project path")
    return project


def parse_source(value: str | Mapping[str, object], base: Path) -> Source | None:
    """Normalize Git identities without discarding declared ref/revision constraints."""
    attributes: dict[str, object]
    if isinstance(value, str):
        attributes = {"url": value}
    elif isinstance(value, Mapping):
        attributes = dict(value)
    else:
        raise FlurryError("Source must be a URL or attribute set")
    allowed = {"type", "url", "owner", "repo", "host", "ref", "rev", "dir", "flake", "narHash", "lastModified", "revCount", "id", "path"}
    unknown = set(attributes) - allowed
    if unknown:
        raise FlurryError("Unsupported source attributes: " + ", ".join(sorted(unknown)))
    flake = attributes.get("flake", True)
    if not isinstance(flake, bool):
        raise FlurryError("Source flake must be a Boolean")
    kind = attributes.get("type")
    if kind == "indirect":
        raise FlurryError("Registry source resolution is unsupported; use an explicit Git source")
    if kind in ("path", "tarball", "file", "mercurial", "sourcehut"):
        return None
    if kind is not None and kind not in ("git", "github", "gitlab"):
        raise FlurryError(f"Unsupported source type: {kind}")
    if "url" not in attributes:
        if kind not in ("github", "gitlab"):
            raise FlurryError("Git source has no URL")
        owner = _text(attributes.get("owner"), "source owner")
        repo = _text(attributes.get("repo"), "source repository")
        raw = f"{kind}:{quote(owner, safe='')}/{quote(repo, safe='')}"
    else:
        raw = _text(attributes["url"], "source URL")
    if ":" not in raw or raw.startswith(("/", "./", "../")):
        local = (base / raw).resolve()
        if (local / ".git").exists() or ((local / "HEAD").is_file() and (local / "objects").is_dir()):
            raw = "git+" + local.as_uri()
    if any(c.isspace() for c in raw) or "\\" in raw:
        raise FlurryError("Invalid whitespace or backslash in source URL")
    try:
        parsed = urlsplit(raw)
    except ValueError as error:
        raise FlurryError("Malformed source URL") from error
    if parsed.scheme == "indirect":
        raise FlurryError("Registry source resolution is unsupported; use an explicit Git source")
    if parsed.scheme in ("path", "tarball", "http", "sourcehut", "mercurial"):
        return None
    if parsed.fragment:
        raise FlurryError("Source URL fragments are unsupported")
    query = parse_qs(parsed.query, keep_blank_values=True)
    if set(query) - {"ref", "rev", "dir", "host"} or any(len(items) != 1 for items in query.values()):
        raise FlurryError("Unsupported or repeated source URL parameter")
    fields = {key: items[0] for key, items in query.items()}
    for key in ("ref", "rev", "dir", "host"):
        if key in attributes:
            if key in fields and fields[key] != attributes[key]:
                raise FlurryError(f"Conflicting source {key}")
            fields[key] = attributes[key]
    ref = _ref(fields["ref"]) if "ref" in fields else None
    rev = _text(fields["rev"], "source revision") if "rev" in fields else None
    if rev is not None and not re.fullmatch(r"[0-9a-fA-F]{7,64}", rev):
        raise FlurryError("Source revision must be a hexadecimal commit identifier")
    directory = _directory(fields.get("dir"))
    host: str | None
    project: str | None
    if parsed.scheme in ("github", "gitlab"):
        transport = parsed.scheme
        if parsed.netloc or parsed.path.startswith("/"):
            raise FlurryError("Hosted Git source must use owner/repository shorthand")
        parts = parsed.path.split("/")
        if len(parts) < 2:
            raise FlurryError("Hosted Git source requires owner/repository")
        project = _project("/".join(parts[:2]))
        if len(parts) > 2:
            suffix = unquote("/".join(parts[2:]))
            if ref is not None or rev is not None:
                raise FlurryError("Duplicate hosted source revision/ref")
            if re.fullmatch(r"[0-9a-fA-F]{40}|[0-9a-fA-F]{64}", suffix):
                rev = suffix
            else:
                ref = _ref(suffix)
        host = _host(fields.get("host", "github.com" if transport == "github" else "gitlab.com"))
        if transport == "github":
            project = project.lower()
        clone_url = f"https://{host}/{project}.git"
        owner, repo = project.rsplit("/", 1)
        normalized = f"{transport}:{quote(owner, safe='')}/{quote(repo, safe='')}"
        default_host = "github.com" if transport == "github" else "gitlab.com"
        parameters = {key: item for key, item in (("host", host if host != default_host else None), ("ref", ref), ("rev", rev), ("dir", directory or None)) if item is not None}
        url = normalized + ("?" + urlencode(parameters) if parameters else "")
        identity = f"{host}/{project}"
    else:
        scheme = parsed.scheme.removeprefix("git+")
        scp = re.fullmatch(r"(?:([A-Za-z0-9_.-]+)@)?([A-Za-z0-9.-]+):([^?#]+)", raw)
        if scheme not in ("https", "ssh", "file") and scp is not None and "://" not in raw:
            user, hostname, project_path = scp.groups()
            host = _host(hostname)
            project = _project(project_path)
            if host == "github.com":
                project = project.lower()
            clone_url = f"ssh://{_user(user)}{host}/{quote(project, safe='/')}.git"
        elif scheme in ("https", "ssh"):
            if parsed.password is not None or (scheme == "https" and parsed.username is not None):
                raise FlurryError("Credentials in source URLs are forbidden")
            if not parsed.hostname:
                raise FlurryError("Git URL has no host")
            try:
                port = parsed.port
            except ValueError as error:
                raise FlurryError("Invalid Git URL port") from error
            if port == (443 if scheme == "https" else 22):
                port = None
            host = _host(parsed.hostname + (f":{port}" if port else ""))
            project = _project(parsed.path)
            if host == "github.com":
                project = project.lower()
            authority = _user(parsed.username) + host
            clone_url = urlunsplit((scheme, authority, "/" + quote(project, safe="/") + ".git", "", ""))
        elif scheme == "file":
            if parsed.netloc not in ("", "localhost"):
                raise FlurryError("File Git source must be local")
            local = Path(_text(unquote(parsed.path), "file Git path"))
            if not local.is_absolute():
                local = base / local
            clone_url = local.resolve().as_uri()
            host, project = None, None
        elif not parsed.scheme:
            if raw.startswith(("/", "./", "../")):
                return None
            raise FlurryError("Registry source resolution is unsupported; use an explicit Git source")
        else:
            raise FlurryError("Unsupported source URL scheme")
        if "host" in fields:
            raise FlurryError("host is only valid for GitHub/GitLab source declarations")
        identity = f"{host}/{project}" if host is not None else clone_url
        parameters = {key: item for key, item in (("ref", ref), ("rev", rev), ("dir", directory or None)) if item is not None}
        url = "git+" + clone_url + ("?" + urlencode(parameters) if parameters else "")
    return Source(identity, url, clone_url, host, project, ref, rev, directory, flake)
