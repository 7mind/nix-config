from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from enum import Enum
from typing import TYPE_CHECKING
from urllib.parse import quote

from .process import FlurryError, Runner

if TYPE_CHECKING:
    from .source import Source


class PermissionState(str, Enum):
    WRITABLE = "writable"
    READ_ONLY = "read-only"
    UNKNOWN = "unknown"


@dataclass(frozen=True)
class Permission:
    repository_id: str
    host: str | None
    principal: str | None
    state: PermissionState
    observed_at: str
    evidence: tuple[str, ...]
    reason: str
    default_branch: str | None
    branch_can_push: bool | None

    def to_dict(self) -> dict[str, object]:
        return asdict(self)


class Permissions:
    def __init__(self, runner: Runner, gitlab_hosts: tuple[str, ...]):
        self.runner = runner
        self.gitlab_hosts = frozenset(("gitlab.com", *gitlab_hosts))

    def check(self, source: Source) -> Permission:
        principal = None
        evidence: list[str] = []
        observed = datetime.now(timezone.utc).isoformat()

        def decision(state: PermissionState, reason: str, branch: str | None,
                     can_push: bool | None) -> Permission:
            return Permission(source.repository_id, source.host, principal, state,
                              observed, tuple(evidence), reason, branch, can_push)

        if source.host is None or source.project is None:
            return decision(PermissionState.UNKNOWN, "No supported authenticated forge identity", None, None)
        if source.host == "github.com":
            tool = "gh"
            forge = "GitHub"
        elif source.host in self.gitlab_hosts:
            tool = "glab"
            forge = "GitLab"
        else:
            return decision(PermissionState.UNKNOWN, "Unsupported forge host; configure a GitLab host explicitly", None, None)

        def api(endpoint: str) -> dict[str, object]:
            result = self.runner.call([tool, "api", "--hostname", source.host, endpoint],
                                      None, None, {}, False)
            if result.returncode:
                raise FlurryError(f"{forge} permission API failed (exit {result.returncode}); "
                                  f"check authentication, token scopes and rate limits")
            try:
                document = json.loads(result.stdout)
            except (ValueError, UnicodeError) as error:
                raise FlurryError(f"{forge} permission API returned invalid JSON") from error
            if not isinstance(document, dict):
                raise FlurryError(f"{forge} permission API returned a non-object")
            return document

        try:
            user = api("user")
            username = user.get("login" if tool == "gh" else "username")
            user_id = user.get("id")
            if not isinstance(username, str) or not username or not isinstance(user_id, (str, int)):
                raise FlurryError(f"{forge} did not identify its authenticated principal")
            principal = f"{username} (id {user_id})"
            evidence.append(f"{tool} api user: authenticated API principal; Git transport credentials may differ")
            if tool == "gh":
                repository = api(f"repos/{quote(source.project, safe='/')}")
                branch = repository.get("default_branch")
                branch = branch if isinstance(branch, str) and branch else None
                if repository.get("archived") is True or repository.get("disabled") is True:
                    return decision(PermissionState.READ_ONLY, "Repository is archived or disabled", branch, None)
                permissions = repository.get("permissions")
                if not isinstance(permissions, dict) or type(permissions.get("push")) is not bool:
                    return decision(PermissionState.UNKNOWN, "GitHub did not expose permissions.push", branch, None)
                push = permissions["push"]
                evidence.append(f"GitHub repository permissions.push={str(push).lower()}")
                return decision(PermissionState.WRITABLE if push else PermissionState.READ_ONLY,
                                "Repository code-write eligibility only; token restrictions and branch rules may prevent publication",
                                branch, None)

            repository = api(f"projects/{quote(source.project, safe='')}")
            branch = repository.get("default_branch")
            branch = branch if isinstance(branch, str) and branch else None
            if repository.get("archived") is True or repository.get("marked_for_deletion_on"):
                return decision(PermissionState.READ_ONLY, "Project is archived or marked for deletion", branch, None)
            permissions = repository.get("permissions")
            if not isinstance(permissions, dict):
                return decision(PermissionState.UNKNOWN, "GitLab did not expose effective project/group access", branch, None)
            levels: list[int] = []
            for key in ("project_access", "group_access"):
                if key not in permissions:
                    return decision(PermissionState.UNKNOWN, "GitLab omitted effective membership evidence", branch, None)
                membership = permissions[key]
                if membership is None:
                    levels.append(0)
                    continue
                if not isinstance(membership, dict) or membership.get("member_role_id") is not None:
                    return decision(PermissionState.UNKNOWN, "Unsupported GitLab custom membership role", branch, None)
                level = membership.get("access_level")
                if type(level) is not int or level not in {0, 5, 10, 15, 20, 30, 40, 50}:
                    return decision(PermissionState.UNKNOWN, "Unsupported GitLab access level", branch, None)
                levels.append(level)
            level = max(levels)
            evidence.append(f"GitLab effective project/group access_level={level}")
            can_push = None
            if branch is not None:
                branch_info = api(f"projects/{quote(source.project, safe='')}/repository/branches/{quote(branch, safe='')}")
                if type(branch_info.get("can_push")) is bool:
                    can_push = branch_info["can_push"]
                    evidence.append(f"GitLab default branch can_push={str(can_push).lower()}")
            return decision(PermissionState.WRITABLE if level >= 30 else PermissionState.READ_ONLY,
                            "Standard repository role; default-branch protection is separate and Git transport/token scopes may differ",
                            branch, can_push)
        except FlurryError as error:
            return decision(PermissionState.UNKNOWN,
                            f"{error}. Install {tool} if missing, then run {tool} auth login --hostname {source.host}",
                            None, None)
