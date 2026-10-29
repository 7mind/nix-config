from __future__ import annotations

import json
import unittest
from types import SimpleNamespace

from flurry.permissions import PermissionState, Permissions
from flurry.process import FlurryError, Result


class ApiRunner:
    def __init__(self, documents: dict[str, object], missing: bool):
        self.documents = documents
        self.missing = missing
        self.calls: list[list[str]] = []

    def call(self, args, cwd, input_data, extra_env, check):
        self.calls.append(args)
        if self.missing:
            raise FlurryError("Cannot execute glab: no such file")
        value = self.documents[args[-1]]
        if isinstance(value, int):
            return Result(b"", b"secret response must not be printed", value)
        return Result(json.dumps(value).encode(), b"", 0)


def source(host: str, project: str):
    return SimpleNamespace(repository_id=f"{host}/{project}", host=host, project=project,
                           url=f"git+https://{host}/{project}.git")


class PermissionsTests(unittest.TestCase):
    def test_github_writable_principal_and_transport_caveat(self):
        runner = ApiRunner({"user": {"login": "builder", "id": 42},
                            "repos/team/repo": {"permissions": {"push": True}, "default_branch": "main"}}, False)
        decision = Permissions(runner, ()).check(source("github.com", "team/repo"))
        self.assertEqual(decision.state, PermissionState.WRITABLE)
        self.assertEqual(decision.principal, "builder (id 42)")
        self.assertIn("transport", " ".join(decision.evidence))
        self.assertIsNone(decision.branch_can_push)
        self.assertEqual(decision.to_dict()["state"], "writable")
        self.assertTrue(all(args[:4] == ["gh", "api", "--hostname", "github.com"] for args in runner.calls))

    def test_github_denial_archived_and_missing_are_distinct(self):
        for fields, expected in [({"permissions": {"push": False}}, PermissionState.READ_ONLY),
                                 ({"archived": True, "permissions": {"push": True}}, PermissionState.READ_ONLY),
                                 ({"disabled": True, "permissions": {"push": True}}, PermissionState.READ_ONLY),
                                 ({"permissions": {"push": "yes"}}, PermissionState.UNKNOWN),
                                 ({}, PermissionState.UNKNOWN)]:
            with self.subTest(fields=fields):
                runner = ApiRunner({"user": {"login": "builder", "id": 42}, "repos/team/repo": fields}, False)
                self.assertEqual(Permissions(runner, ()).check(source("github.com", "team/repo")).state, expected)

    def test_api_failure_unknown_without_response_leak(self):
        runner = ApiRunner({"user": {"login": "builder", "id": 42}, "repos/team/repo": 1}, False)
        decision = Permissions(runner, ()).check(source("github.com", "team/repo"))
        self.assertEqual(decision.state, PermissionState.UNKNOWN)
        self.assertNotIn("secret", decision.reason)
        self.assertIn("auth login", decision.reason)

    def test_gitlab_inherited_role_is_writable_protected_default_is_separate(self):
        runner = ApiRunner({"user": {"username": "builder", "id": 42},
                            "projects/team%2Fsub%2Frepo": {"default_branch": "main", "permissions": {
                                "project_access": {"access_level": 10}, "group_access": {"access_level": 30}}},
                            "projects/team%2Fsub%2Frepo/repository/branches/main": {"can_push": False}}, False)
        decision = Permissions(runner, ("gitlab.example",)).check(source("gitlab.example", "team/sub/repo"))
        self.assertEqual(decision.state, PermissionState.WRITABLE)
        self.assertFalse(decision.branch_can_push)
        self.assertEqual(decision.default_branch, "main")
        self.assertTrue(all(args[:4] == ["glab", "api", "--hostname", "gitlab.example"] for args in runner.calls))

    def test_gitlab_reader_custom_role_unknown_role_and_archived(self):
        for fields, expected in [({"permissions": {"project_access": None, "group_access": {"access_level": 20}}}, PermissionState.READ_ONLY),
                                 ({"permissions": {"project_access": {"access_level": 30, "member_role_id": 5}}}, PermissionState.UNKNOWN),
                                 ({"permissions": {"group_access": {"access_level": 99}}}, PermissionState.UNKNOWN),
                                 ({"archived": True}, PermissionState.READ_ONLY),
                                 ({}, PermissionState.UNKNOWN)]:
            with self.subTest(fields=fields):
                runner = ApiRunner({"user": {"username": "builder", "id": 42}, "projects/team%2Frepo": fields}, False)
                self.assertEqual(Permissions(runner, ()).check(source("gitlab.com", "team/repo")).state, expected)

    def test_gitlab_absent_membership_evidence_is_unknown_not_readonly(self):
        for fields in ({}, {"project_access": None}, {"group_access": {"access_level": 20}}):
            with self.subTest(fields=fields):
                runner = ApiRunner({"user": {"username": "builder", "id": 42},
                                    "projects/team%2Frepo": {"permissions": fields}}, False)
                self.assertEqual(Permissions(runner, ()).check(source("gitlab.com", "team/repo")).state,
                                 PermissionState.UNKNOWN)

    def test_missing_glab_unknown_with_authentication_instructions(self):
        decision = Permissions(ApiRunner({}, True), ("gitlab.example",)).check(source("gitlab.example", "team/repo"))
        self.assertEqual(decision.state, PermissionState.UNKNOWN)
        self.assertIn("Install glab", decision.reason)
        self.assertIn("glab auth login --hostname gitlab.example", decision.reason)

    def test_github_shorthand_cannot_authorize_credentials_for_an_arbitrary_host(self):
        runner = ApiRunner({"user": {"login": "builder", "id": 42},
                            "repos/team/repo": {"permissions": {"push": True}}}, False)
        dependency = source("untrusted.example", "team/repo")
        dependency.url = "github:team/repo?host=untrusted.example"
        decision = Permissions(runner, ()).check(dependency)
        self.assertEqual(decision.state, PermissionState.UNKNOWN)
        self.assertEqual(runner.calls, [])

    def test_unknown_host_never_tries_credentials(self):
        runner = ApiRunner({}, False)
        decision = Permissions(runner, ()).check(source("unknown.example", "team/repo"))
        self.assertEqual(decision.state, PermissionState.UNKNOWN)
        self.assertEqual(runner.calls, [])


if __name__ == "__main__":
    unittest.main()
