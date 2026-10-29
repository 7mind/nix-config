from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import tempfile
import unittest
from pathlib import Path

from flurry.nix import Nix
from flurry.permissions import Permission, PermissionState
from flurry.process import FlurryError, Runner
from flurry.pull import Pull

REVISION = "a" * 40


def node(project: str, inputs: dict[str, object], ref: str | None):
    original = {"type": "github", "owner": "team", "repo": project}
    if ref is not None:
        original["ref"] = ref
    return {"locked": {"type": "github", "owner": "team", "repo": project, "rev": REVISION},
            "original": original, "inputs": inputs}


def lock(nodes: dict[str, object], inputs: dict[str, object]):
    return {"version": 7, "root": "root", "nodes": {"root": {"inputs": inputs}, **nodes}}


class PermissionDummy:
    def __init__(self, states: dict[str, PermissionState]):
        self.states = states
        self.checked: list[str] = []

    def check(self, source):
        self.checked.append(source.repository_id)
        state = self.states.get(source.repository_id, PermissionState.WRITABLE)
        return Permission(source.repository_id, source.host, "test-user", state, "test-time", (),
                          f"Fixture permission {state.value}", "main", None)


class GitDummy:
    def __init__(self, metadata: dict[str, object]):
        self.metadata = metadata
        self.checkouts: dict[Path, tuple[str, str, str]] = {}
        self.refs = {"refs/heads/main", "refs/heads/dev", "refs/tags/v1"}
        self.commands: list[list[str]] = []
        self.fail_clone = False
        self.appear_destination: Path | None = None

    def run(self, args, cwd):
        self.commands.append(args)
        if args[0] == "nix":
            return json.dumps({"locks": self.metadata}).encode()
        if "clone" in args:
            path = Path(args[-1])
            path.mkdir()
            (path / ".git").mkdir()
            if self.appear_destination is not None:
                self.appear_destination.mkdir()
            if self.fail_clone:
                raise FlurryError("Injected clone failure")
            self.checkouts[path] = (args[-2], args[args.index("--branch") + 1], REVISION)
            return b""
        raise AssertionError(args)

    def text(self, args, cwd):
        self.commands.append(args)
        if "ls-remote" not in args:
            raise AssertionError(args)
        return "ref: refs/heads/main\tHEAD\n" + "\n".join(f"{REVISION}\t{ref}" for ref in sorted(self.refs))

    def git_text(self, path, *args):
        remote, branch, revision = self.checkouts[path]
        if args == ("rev-parse", "--show-toplevel"):
            return str(path)
        if args == ("remote", "get-url", "origin"):
            return remote
        if args == ("symbolic-ref", "HEAD"):
            return f"refs/heads/{branch}"
        if args == ("rev-parse", "HEAD"):
            return revision
        raise AssertionError(args)

    def existing(self, path: Path, remote: str):
        path.mkdir()
        (path / ".git").mkdir()
        self.checkouts[path] = (remote, "work-in-progress", REVISION)


class MetadataRunner(Runner):
    def __init__(self, metadata: dict[str, object]):
        super().__init__(os.environ, 30)
        self.metadata = metadata

    def run(self, args, cwd):
        if args[0] == "nix":
            return json.dumps({"locks": self.metadata}).encode()
        return super().run(args, cwd)


class PullPlanningTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.checkout = self.root / "root"
        self.checkout.mkdir()
        (self.checkout / "flake.nix").write_text("{ outputs = _: {}; }")
        (self.checkout / "flake.lock").write_text("{}")

    def planner(self, graph, states):
        runner = GitDummy(graph)
        permissions = PermissionDummy(states)
        return Pull(runner, Nix(runner), permissions), runner, permissions

    def test_traverses_readonly_and_excluded_nodes_and_follows(self):
        graph = lock({"readonly": node("readonly", {"child": "writable"}, None),
                      "writable": node("writable", {}, None),
                      "excluded": node("excluded", {"other": "another"}, None),
                      "another": node("another", {}, None)},
                     {"first": "readonly", "second": "excluded", "alias": ["first", "child"]})
        pull, runner, permissions = self.planner(graph, {"github.com/team/readonly": PermissionState.READ_ONLY})
        plan = pull.plan("root", self.root, ("excluded",), {})
        self.assertTrue(plan.complete, plan.to_dict())
        actions = {entry.repository_id: entry.action for entry in plan.entries}
        self.assertEqual(actions, {"github.com/team/readonly": "read-only", "github.com/team/writable": "clone",
                                   "github.com/team/excluded": "excluded", "github.com/team/another": "clone"})
        self.assertNotIn("github.com/team/excluded", permissions.checked)
        self.assertIn("--no-update-lock-file", runner.commands[0])
        self.assertIn("--no-accept-flake-config", runner.commands[0])
        self.assertIn("allow-import-from-derivation", runner.commands[0])
        self.assertIn("locked dependency closure", plan.warnings[0])
        json.dumps(plan.to_dict())

    def test_local_symlink_lock_is_rejected_before_metadata_reads(self):
        outside = self.root / "outside.lock"
        outside.write_text("{}")
        (self.checkout / "flake.lock").unlink()
        (self.checkout / "flake.lock").symlink_to(outside)
        pull, runner, _ = self.planner(lock({}, {}), {})
        plan = pull.plan("root", self.root, (), {})
        self.assertFalse(plan.complete)
        self.assertIn("symlink", " ".join(plan.issues))
        self.assertEqual(runner.commands, [])

    def test_unknown_permission_blocks_clone_phase(self):
        pull, runner, _ = self.planner(lock({"a": node("a", {}, None), "b": node("b", {}, None)}, {"a": "a", "b": "b"}),
                                       {"github.com/team/b": PermissionState.UNKNOWN})
        plan = pull.plan("root", self.root, (), {})
        self.assertFalse(plan.complete)
        with self.assertRaisesRegex(FlurryError, "no clones were started"):
            pull.apply(plan)
        self.assertFalse(any("clone" in command for command in runner.commands))

    def test_multiple_revisions_and_subdirectories_materialize_once(self):
        first = node("same", {}, None)
        second = node("same", {}, None)
        second["locked"]["rev"] = "b" * 40
        second["locked"]["dir"] = "nested"
        graph = lock({"one": first, "two": second}, {"one": "one", "two": "two"})
        pull, _, permissions = self.planner(graph, {})
        plan = pull.plan("root", self.root, (), {})
        self.assertTrue(plan.complete)
        self.assertEqual(len(plan.entries), 1)
        self.assertEqual(plan.entries[0].locked_revisions, (REVISION, "b" * 40))
        self.assertEqual(len(permissions.checked), 1)

    def test_conflicting_branches_and_ambiguous_branch_tag(self):
        graph = lock({"one": node("same", {}, "main"), "two": node("same", {}, "dev")}, {"one": "one", "two": "two"})
        pull, runner, _ = self.planner(graph, {})
        plan = pull.plan("root", self.root, (), {})
        self.assertFalse(plan.complete)
        self.assertIn("Conflicting branch", plan.entries[0].reason)
        runner.metadata = lock({"one": node("same", {}, "v1")}, {"one": "one"})
        runner.refs.add("refs/heads/v1")
        plan = pull.plan("root", self.root, (), {})
        self.assertFalse(plan.complete)
        self.assertIn("Ambiguous branch/tag", plan.entries[0].reason)

    def test_tag_and_pinned_revision_use_default_branch_tip(self):
        for ref in ("v1", "refs/tags/v1", None):
            with self.subTest(ref=ref):
                pull, _, _ = self.planner(lock({"a": node("a", {}, ref)}, {"a": "a"}), {})
                plan = pull.plan("root", self.root, (), {})
                self.assertTrue(plan.complete)
                self.assertEqual(plan.entries[0].branch, "main")

    def test_explicit_branch_ref(self):
        pull, _, _ = self.planner(lock({"a": node("a", {}, "refs/heads/dev")}, {"a": "a"}), {})
        plan = pull.plan("root", self.root, (), {})
        self.assertTrue(plan.complete)
        self.assertEqual(plan.entries[0].branch, "dev")

    def test_existing_matching_checkout_reused_without_ref_queries(self):
        pull, runner, _ = self.planner(lock({"a": node("a", {}, None)}, {"a": "a"}), {})
        runner.existing(self.root / "a", "git@github.com:team/a.git")
        plan = pull.plan("root", self.root, (), {})
        self.assertTrue(plan.complete)
        self.assertEqual(plan.entries[0].action, "reuse")
        self.assertFalse(any("ls-remote" in command for command in runner.commands))
        self.assertEqual(pull.apply(plan)[0].action, "reused")
        self.assertEqual(runner.checkouts[self.root / "a"][1], "work-in-progress")

    def test_collision_and_mapping(self):
        graph = lock({"a": node("same", {}, None), "b": {"original": {"type": "github", "owner": "other", "repo": "same"},
                     "locked": {"type": "github", "owner": "other", "repo": "same", "rev": REVISION}}}, {"a": "a", "b": "b"})
        pull, _, _ = self.planner(graph, {})
        plan = pull.plan("root", self.root, (), {})
        self.assertFalse(plan.complete)
        self.assertTrue(all(entry.action == "blocked" for entry in plan.entries))
        plan = pull.plan("root", self.root, (), {"github.com/other/same": "other-same"})
        self.assertTrue(plan.complete)
        self.assertEqual({Path(entry.destination).name for entry in plan.entries}, {"same", "other-same"})

    def test_url_mapping(self):
        pull, _, _ = self.planner(lock({"a": node("a", {}, None)}, {"a": "a"}), {})
        plan = pull.plan("root", self.root, (), {f"github:team/a?rev={REVISION}": "custom"})
        self.assertTrue(plan.complete)
        self.assertEqual(plan.entries[0].destination, str(self.root / "custom"))

    def test_plain_remote_url_mapping_normalizes_repository_identity(self):
        pull, _, _ = self.planner(lock({"a": node("a", {}, None)}, {"a": "a"}), {})
        plan = pull.plan("root", self.root, (), {"https://github.com/team/a.git": "custom"})
        self.assertTrue(plan.complete)
        self.assertEqual(plan.entries[0].destination, str(self.root / "custom"))

    def test_nested_destinations_conflict(self):
        pull, _, _ = self.planner(lock({"a": node("a", {}, None), "b": node("b", {}, None)}, {"a": "a", "b": "b"}), {})
        plan = pull.plan("root", self.root, (), {"github.com/team/a": "a", "github.com/team/b": "a/b"})
        self.assertFalse(plan.complete)
        self.assertTrue(all(entry.action == "blocked" for entry in plan.entries))

    def test_workspace_root_replaced_by_symlink_before_apply_is_rejected(self):
        workspace = self.root / "workspace"
        workspace.mkdir()
        (workspace / "root").mkdir()
        (workspace / "root" / "flake.nix").write_text("{ outputs = _: {}; }")
        pull, _, _ = self.planner(lock({"a": node("a", {}, None)}, {"a": "a"}), {})
        plan = pull.plan("root", workspace, (), {})
        workspace.rename(self.root / "old-workspace")
        outside = self.root / "outside"
        outside.mkdir()
        workspace.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(FlurryError, "symlink"):
            pull.apply(plan)
        self.assertEqual(list(outside.iterdir()), [])

    def test_all_destinations_revalidated_before_first_clone(self):
        pull, runner, _ = self.planner(lock({"a": node("a", {}, None), "b": node("b", {}, None)}, {"a": "a", "b": "b"}), {})
        plan = pull.plan("root", self.root, (), {})
        (self.root / "b").symlink_to(self.checkout, target_is_directory=True)
        with self.assertRaisesRegex(FlurryError, "symlink"):
            pull.apply(plan)
        self.assertFalse(any("clone" in command for command in runner.commands))
        self.assertFalse((self.root / "a").exists())

    def test_missing_destination_parent_is_preflight_blocker(self):
        pull, _, _ = self.planner(lock({"a": node("a", {}, None), "b": node("b", {}, None)}, {"a": "a", "b": "b"}), {})
        plan = pull.plan("root", self.root, (), {"github.com/team/b": "missing/b"})
        self.assertFalse(plan.complete)
        self.assertEqual(next(entry for entry in plan.entries if entry.repository_id.endswith("/b")).action, "blocked")

    def test_identity_mismatch_path_escape_and_symlink_block(self):
        pull, runner, _ = self.planner(lock({"a": node("a", {}, None)}, {"a": "a"}), {})
        runner.existing(self.root / "a", "https://github.com/other/a.git")
        self.assertFalse(pull.plan("root", self.root, (), {}).complete)
        self.assertFalse(pull.plan("root", self.root, (), {"github.com/team/a": "../a"}).complete)
        (self.root / "link").symlink_to(self.checkout, target_is_directory=True)
        self.assertFalse(pull.plan("root", self.root, (), {"github.com/team/a": "link/new"}).complete)

    def test_non_git_source_skip_still_traverses_edges_and_unknown_type_blocks(self):
        graph = lock({"non-git": {"locked": {"type": "path", "path": "./x"}, "inputs": {"child": "child"}},
                      "child": node("child", {}, None)}, {"non-git": "non-git"})
        pull, runner, _ = self.planner(graph, {})
        plan = pull.plan("root", self.root, (), {})
        self.assertTrue(plan.complete)
        self.assertEqual(len(plan.entries), 1)
        self.assertTrue(any("Non-Git source skipped" in warning for warning in plan.warnings))
        runner.metadata["nodes"]["non-git"]["locked"]["type"] = "unrecognized"
        self.assertFalse(pull.plan("root", self.root, (), {}).complete)

    def test_finite_node_cycle_and_alias_cycle(self):
        graph = lock({"a": node("a", {"b": "b"}, None), "b": node("b", {"a": "a"}, None)}, {"a": "a"})
        pull, runner, _ = self.planner(graph, {})
        self.assertTrue(pull.plan("root", self.root, (), {}).complete)
        runner.metadata = lock({}, {"alias": ["alias"]})
        plan = pull.plan("root", self.root, (), {})
        self.assertFalse(plan.complete)
        self.assertIn("Cyclic lock follows", plan.issues[0])

    def test_flake_false_source_materialized(self):
        item = node("a", {}, None)
        item["flake"] = False
        pull, _, _ = self.planner(lock({"a": item}, {"a": "a"}), {})
        self.assertTrue(pull.plan("root", self.root, (), {}).complete)

    def test_clone_failure_retains_identified_partial_directory(self):
        pull, runner, _ = self.planner(lock({"a": node("a", {}, None)}, {"a": "a"}), {})
        plan = pull.plan("root", self.root, (), {})
        runner.fail_clone = True
        with self.assertRaisesRegex(FlurryError, "partial clone retained at"):
            pull.apply(plan)
        self.assertFalse((self.root / "a").exists())
        self.assertEqual(len(list(self.root.glob(".flurry-pull-*/checkout/.git"))), 1)

    def test_publication_does_not_replace_empty_destination_appearing_during_clone(self):
        pull, runner, _ = self.planner(lock({"a": node("a", {}, None)}, {"a": "a"}), {})
        plan = pull.plan("root", self.root, (), {})
        runner.appear_destination = self.root / "a"
        with self.assertRaisesRegex(FlurryError, "not overwritten"):
            pull.apply(plan)
        self.assertEqual(list((self.root / "a").iterdir()), [])
        self.assertEqual(len(list(self.root.glob(".flurry-pull-*/checkout/.git"))), 1)

    def test_unknown_bare_root_does_not_resolve_registries(self):
        pull, runner, _ = self.planner(lock({}, {}), {})
        plan = pull.plan("unknown-owner", self.root, (), {})
        self.assertFalse(plan.complete)
        self.assertEqual(runner.commands, [])

    def test_remote_root_materialized_under_same_permission_rules(self):
        pull, _, _ = self.planner(lock({}, {}), {})
        plan = pull.plan("github:team/root", self.root, (), {"github.com/team/root": "root-clone"})
        self.assertTrue(plan.complete)
        self.assertEqual(plan.entries[0].repository_id, "github.com/team/root")
        self.assertEqual(plan.entries[0].action, "clone")

    def test_missing_lock_metadata_is_not_empty_success(self):
        pull, runner, _ = self.planner({}, {})
        plan = pull.plan("root", self.root, (), {})
        self.assertFalse(plan.complete)
        self.assertIn("lock graph", plan.issues[0])


class CloneContract:
    def test_clone_tip_and_reuse_second_run(self):
        pull, branch_tip = self.make_pull()
        plan = pull.plan("root", self.root, (), self.mapping)
        self.assertTrue(plan.complete, plan.to_dict())
        result = pull.apply(plan)
        self.assertEqual(result[0].action, "cloned")
        self.assertEqual(result[0].revision, branch_tip)
        self.after_clone(pull)
        plan = pull.plan("root", self.root, (), self.mapping)
        self.assertTrue(plan.complete, plan.to_dict())
        self.assertEqual(plan.entries[0].action, "reuse")
        self.assertEqual(pull.apply(plan)[0].action, "reused")


class DummyCloneContract(CloneContract, unittest.TestCase):
    def make_pull(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        checkout = self.root / "root"
        checkout.mkdir()
        (checkout / "flake.nix").write_text("{ outputs = _: {}; }")
        runner = GitDummy(lock({"a": node("a", {}, None)}, {"a": "a"}))
        self.mapping = {}
        return Pull(runner, Nix(runner), PermissionDummy({})), REVISION

    def after_clone(self, pull):
        entry = next(iter(pull.runner.checkouts.values()))
        pull.runner.checkouts[self.root / "a"] = entry
        self.assertTrue((self.root / "a" / ".git").is_dir())


@unittest.skipUnless(shutil.which("git"), "local Git adapter requires git")
class LocalGitCloneContract(CloneContract, unittest.TestCase):
    def git(self, directory, *args):
        environment = dict(os.environ) | {"GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
                                           "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.invalid"}
        return subprocess.check_output(["git", "-C", str(directory), "-c", "core.hooksPath=/dev/null", *args], env=environment,
                                       stderr=subprocess.PIPE).decode().strip()

    def make_pull(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        checkout = self.root / "root"
        checkout.mkdir()
        (checkout / "flake.nix").write_text("{ outputs = _: {}; }")
        provider = self.root / "provider"
        provider.mkdir()
        self.git(provider, "init", "-b", "main")
        (provider / "flake.nix").write_text("{ outputs = _: {}; }")
        self.git(provider, "add", "flake.nix")
        self.git(provider, "commit", "-m", "Initial")
        pinned = self.git(provider, "rev-parse", "HEAD")
        (provider / "tip").write_text("tip\n")
        self.git(provider, "add", "tip")
        self.git(provider, "commit", "-m", "Advance branch tip")
        branch_tip = self.git(provider, "rev-parse", "HEAD")
        remote = self.root / "remote.git"
        self.git(self.root, "clone", "--bare", str(provider), str(remote))
        metadata = lock({"a": {"original": {"type": "git", "url": remote.as_uri()},
                               "locked": {"type": "git", "url": remote.as_uri(), "rev": pinned}}}, {"a": "a"})
        runner = MetadataRunner(metadata)
        self.mapping = {remote.as_uri(): "a"}
        return Pull(runner, Nix(runner), PermissionDummy({})), branch_tip

    def test_explicit_full_branch_ref_with_same_named_tag(self):
        pull, _ = self.make_pull()
        remote = self.root / "remote.git"
        self.git(remote, "tag", "main", "HEAD")
        pull.runner.metadata["nodes"]["a"]["original"]["ref"] = "refs/heads/main"
        plan = pull.plan("root", self.root, (), self.mapping)
        self.assertTrue(plan.complete, plan.to_dict())
        self.assertEqual(pull.apply(plan)[0].action, "cloned")

    def after_clone(self, pull):
        self.assertEqual(self.git(self.root / "a", "symbolic-ref", "--short", "HEAD"), "main")
        self.assertEqual((self.root / "a" / "tip").read_text(), "tip\n")
        (self.root / "a" / "user-edits").write_text("leave me\n")
        self.git(self.root / "a", "checkout", "-b", "user-branch")


@unittest.skipUnless(shutil.which("nix"), "local Nix metadata adapter requires nix")
class LocalNixMetadataTests(unittest.TestCase):
    def test_git_root_metadata_does_not_copy_git_private_files_or_sockets(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            checkout = root / "root"
            checkout.mkdir()
            (checkout / "flake.nix").write_text('{ outputs = _: {}; }')
            runner = Runner(os.environ | {"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
                                         "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
                                         "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid"}, 30)
            runner.run(["git", "init", "--initial-branch=main", str(checkout)], None)
            runner.git(checkout, "add", "flake.nix")
            runner.git(checkout, "commit", "-m", "initial")
            with socket.socket(socket.AF_UNIX) as ipc:
                ipc.bind(str(checkout / ".git" / "fsmonitor--daemon.ipc"))
                plan = Pull(runner, Nix(runner), PermissionDummy({})).plan("root", root, (), {})
                self.assertTrue(plan.complete, plan.to_dict())
            self.assertFalse((checkout / "flake.lock").exists())

    def test_metadata_does_not_evaluate_outputs_or_write_lock(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            checkout = root / "root"
            checkout.mkdir()
            (checkout / "flake.nix").write_text('{ outputs = _: throw "outputs must not be evaluated"; }')
            runner = Runner(os.environ, 30)
            pull = Pull(runner, Nix(runner), PermissionDummy({}))
            plan = pull.plan("root", root, (), {})
            self.assertTrue(plan.complete, plan.to_dict())
            self.assertEqual(plan.entries, ())
            self.assertFalse((checkout / "flake.lock").exists())


if __name__ == "__main__":
    unittest.main()
