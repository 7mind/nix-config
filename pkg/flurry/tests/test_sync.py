"""Effectual-GoodCommunication: actual Git and Nix, temporary file-only remotes."""
import contextlib
import hashlib
import io
import json
import os
import shlex
import shutil
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

from flurry.cli import main
from flurry.git import Git
from flurry.nix import Nix
from flurry.process import FlurryError, Runner, remote_head
from flurry.state import Journal
from flurry.sync import Sync, SyncOptions, frozen_lock, plan_sync
from flurry.workspace import load_config


class FrozenBoundaryTests(unittest.TestCase):
    def test_equivalent_duplicate_lock_nodes_are_not_a_boundary_change(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = {"type": "github", "owner": "example", "repo": "frozen", "rev": "a" * 40}
            (root / "flake.lock").write_text(json.dumps({"nodes": {"one": {"locked": source}, "two": {"locked": source}}}))
            before = frozen_lock(root, {"github.com/example/frozen"})
            (root / "flake.lock").write_text(json.dumps({"nodes": {"one": {"locked": source}}}))
            self.assertEqual(before, frozen_lock(root, {"github.com/example/frozen"}))


class SyncFixture:
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="flurry-sync-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.root = self.directory / "workspace with spaces"
        self.root.mkdir()
        self.origins = self.directory / "origins"
        self.origins.mkdir()
        self.seeds = self.directory / "seeds"
        self.seeds.mkdir()
        home = self.directory / "home"
        home.mkdir()
        self.env = os.environ | {
            "HOME": str(home), "XDG_CACHE_HOME": str(home / ".cache"),
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
            "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
            "GIT_ALLOW_PROTOCOL": "file", "GIT_TERMINAL_PROMPT": "0",
        }
        self.runner = Runner(self.env, 90)
        self.nix = Nix(self.runner)
        self.events = []
        self.sync = Sync(self.runner, self.nix, Git(self.runner), self.events.append)
        self.repos = {}

    def git(self, path, *args):
        return self.runner.git_text(path, *args)

    def add_repo(self, name, dependencies, *, flake=True):
        origin = self.origins / (name + ".git")
        seed = self.seeds / name
        self.runner.run(["git", "init", "--bare", "--initial-branch=main", str(origin)], None)
        self.runner.run(["git", "init", "--initial-branch=main", str(seed)], None)
        inputs = "\n".join(f'  inputs.{key}.url = "git+{self.origins.joinpath(provider + ".git").as_uri()}?ref=main";' for key, provider in dependencies.items())
        args = ", ".join(["self", *dependencies])
        if flake:
            (seed / "flake.nix").write_text("{\n" + inputs + f"\n  outputs = {{ {args} }}: {{ lib.answer = 1; }};\n}}\n")
        (seed / "edit.txt").write_text("base\n")
        self.git(seed, "add", ".")
        if dependencies:
            self.nix.update(seed, tuple(dependencies))
            self.git(seed, "add", "flake.lock")
        self.git(seed, "commit", "-m", "initial")
        self.git(seed, "remote", "add", "origin", origin.as_uri())
        self.git(seed, "push", "-u", "origin", "main")
        repo = self.root / name
        self.runner.run(["git", "clone", "--no-recurse-submodules", str(origin), str(repo)], None)
        self.repos[name] = (repo, origin, seed)
        return repo

    def options(self, mode):
        return SyncOptions(mode, None, None, "eval", ())

    def run_sync(self, options):
        return self.sync.run(load_config(self.root, options.excludes), options, None)

    def remote_head(self, name):
        return self.git(self.repos[name][1], "rev-parse", "refs/heads/main")


class PushAdvertisementTests(unittest.TestCase):
    def test_remote_head_rejects_malformed_output_instead_of_treating_it_as_absent(self):
        ref = "refs/heads/main"
        record = b"a" * 40 + b"\trefs/heads/main\n"
        for output in (b"garbage\n", b"\n", record + b"garbage\n", record * 2, record.replace(b"\t", b" "),
                       b"b" * 41 + b"\trefs/heads/main\n", record.replace(b"main", b"unrelated")):
            with self.subTest(output=output), patch.object(Runner, "run", return_value=output):
                with self.assertRaisesRegex(FlurryError, "Malformed/ambiguous remote ref response"):
                    remote_head(Runner(os.environ, 10), Path("."), "file:///unused", ref)


class LocalGitSyncTests(SyncFixture, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.repo = self.add_repo("a", {}, flake=False)
        (self.root / "flurry.toml").write_text('[repositories.a]\n')
        self.preserve = SyncOptions("preserve", None, None, "none", ())

    def journal(self):
        return json.loads(next((self.root / ".flurry" / "runs").glob("*/run.json")).read_text())

    def test_common_push_tips_need_no_refetch_but_still_push_and_verify(self):
        hook = self.repo / ".git/hooks/pre-push"
        audit = self.directory / "pushes"
        hook.write_text(f'#!/bin/sh\nprintf "push\\n" >> "{audit}"\n')
        hook.chmod(0o755)
        for advancing in (False, True):
            with self.subTest(advancing=advancing):
                if advancing:
                    self.git(self.repo, "commit", "--allow-empty", "-m", "local work")
                head = self.git(self.repo, "rev-parse", "HEAD")
                call = self.runner.call
                with patch.object(self.runner, "call", wraps=call) as trace:
                    result = self.run_sync(self.preserve)
                self.assertEqual(result.document["status"], "complete")
                commands = [entry.args[0] for entry in trace.call_args_list]
                observations = [args for args in commands if "ls-remote" in args]
                self.assertEqual(len(observations), 3)
                self.assertEqual(observations[0][2], observations[1][2])
                self.assertNotEqual(observations[1][2], str(self.repo))
                push, = (args for args in commands if "push" in args and "--recurse-submodules=no" in args)
                self.assertLess(commands.index(push), commands.index(observations[-1]))
                self.assertEqual(observations[-1][2], str(self.repo))
                self.assertFalse(any(args[-1].endswith(":refs/flurry/push-base") for args in commands))
                ancestry = [args for args in commands if "merge-base" in args and args[-1] == head]
                self.assertEqual(len(ancestry), 2 if advancing else 0)
                self.assertEqual(self.remote_head("a"), head)
        self.assertEqual(audit.read_text().splitlines(), ["push", "push"])

    def test_pushurl_is_verified_by_exact_ref_when_only_a_suffix_matches_initially(self):
        _, origin, _ = self.repos["a"]
        initial = self.remote_head("a")
        mirror = self.directory / "mirror.git"
        self.git(self.directory, "clone", "--bare", str(origin), str(mirror))
        self.git(self.repo, "remote", "add", "publisher", mirror.as_uri())
        self.git(self.repo, "remote", "set-url", "--push", "publisher", origin.as_uri())
        ref = "refs/heads/release"
        suffix_ref = "refs/heads/topic/" + ref
        self.git(origin, "update-ref", suffix_ref, initial)
        (self.root / "flurry.toml").write_text(f'[repositories.a]\npush_remote = "publisher"\npush_ref = "{ref}"\n')
        hook = self.repo / ".git/hooks/pre-push"
        audit = self.directory / "push-arguments"
        hook.write_text(f'#!/bin/sh\nprintf "%s\\n" "$@" > "{audit}"\n')
        hook.chmod(0o755)
        self.git(self.repo, "commit", "--allow-empty", "-m", "publish a new branch")
        head = self.git(self.repo, "rev-parse", "HEAD")
        journal = self.run_sync(self.preserve)
        self.assertEqual(journal.document["status"], "complete")
        self.assertEqual(self.git(origin, "rev-parse", ref), head)
        self.assertEqual(self.git(origin, "rev-parse", suffix_ref), initial)
        self.assertEqual(self.git(mirror, "ls-remote", "--refs", "--", str(mirror), ref), "")
        self.assertEqual(audit.read_text().splitlines(), ["publisher", origin.as_uri()])

    def test_different_baseline_ref_fetches_the_push_tip_even_if_already_local(self):
        _, origin, seed = self.repos["a"]
        baseline = self.remote_head("a")
        self.git(origin, "update-ref", "refs/heads/baseline", baseline)
        self.git(seed, "commit", "--allow-empty", "-m", "published since baseline")
        self.git(seed, "push", "origin", "main")
        self.git(self.repo, "pull", "--ff-only")
        self.git(self.repo, "commit", "--allow-empty", "-m", "publish next commit")
        (self.root / "flurry.toml").write_text('[repositories.a]\nrebase_onto = "origin/baseline"\n')
        call = self.runner.call
        with patch.object(self.runner, "call", wraps=call) as trace:
            journal = self.run_sync(self.preserve)
        self.assertEqual(journal.document["status"], "complete")
        fetches = [entry.args[0] for entry in trace.call_args_list if entry.args[0][-1].endswith(":refs/flurry/push-base")]
        self.assertEqual(len(fetches), 2)
        self.assertEqual(self.remote_head("a"), self.git(self.repo, "rev-parse", "HEAD"))

    def test_second_advertisement_rejects_a_remote_move_before_promotion(self):
        _, _, seed = self.repos["a"]
        self.git(self.repo, "commit", "--allow-empty", "-m", "local work")
        local = self.git(self.repo, "rev-parse", "HEAD")
        self.git(seed, "commit", "--allow-empty", "-m", "independent work")
        remote = self.git(seed, "rev-parse", "HEAD")
        call = self.runner.call
        advertised = 0

        def advance_after_first_advertisement(args, *rest):
            nonlocal advertised
            result = call(args, *rest)
            if "ls-remote" in args:
                advertised += 1
                if advertised == 1:
                    self.git(seed, "push", "origin", "main")
            return result

        with patch.object(self.runner, "call", side_effect=advance_after_first_advertisement):
            with self.assertRaisesRegex(FlurryError, "planned push is not fast-forward"):
                self.run_sync(self.preserve)
        self.assertEqual(advertised, 2)
        self.assertEqual(self.remote_head("a"), remote)
        self.assertEqual(self.git(self.repo, "rev-parse", "HEAD"), local)
        self.assertEqual(self.git(self.repo, "for-each-ref", "refs/flurry/"), "")
        self.assertEqual(self.journal()["action"], "locking:a")

    def test_final_rehearsal_failure_remains_resumable_with_dirty_work_preserved(self):
        (self.repo / "edit.txt").write_text("staged\n")
        self.git(self.repo, "add", "edit.txt")
        (self.repo / "edit.txt").write_text("unstaged\n")
        untracked = self.repo / "untracked"
        untracked.write_bytes(b"private\x00\xff")
        call = self.runner.call
        advertised = 0

        def dirty_trial_after_second_advertisement(args, *rest):
            nonlocal advertised
            result = call(args, *rest)
            if "ls-remote" in args:
                advertised += 1
                if advertised == 2:
                    (Path(args[2]) / "late-file").write_text("trial changed\n")
            return result

        with patch.object(self.runner, "call", side_effect=dirty_trial_after_second_advertisement):
            with self.assertRaisesRegex(FlurryError, "Restore rehearsal requires a clean trial"):
                self.run_sync(self.preserve)
        failed = self.journal()
        self.assertEqual(failed["action"], "locking:a")
        self.assertEqual(self.git(self.repo, "for-each-ref", "refs/flurry/"), "")
        self.assertEqual(self.sync.resume(load_config(self.root, ()), failed["id"]).document["status"], "complete")
        self.assertEqual(self.git(self.repo, "show", ":edit.txt"), "staged")
        self.assertEqual((self.repo / "edit.txt").read_text(), "unstaged\n")
        self.assertEqual(untracked.read_bytes(), b"private\x00\xff")

    def test_clean_porcelain_does_not_prove_the_final_checkout_matches(self):
        initial = self.remote_head("a")
        (self.repo / ".gitattributes").write_text("edit.txt text eol=lf\n")
        self.git(self.repo, "add", ".gitattributes")
        self.git(self.repo, "commit", "-m", "text attributes")
        commit_lock = self.sync.git.commit_lock
        for change in ("normalized bytes", "hidden untracked"):
            with self.subTest(change=change):
                def alter_trial(item):
                    commit_lock(item)
                    if change == "normalized bytes":
                        (item.trial / "edit.txt").write_bytes(b"base\r\n")
                        self.git(item.trial, "add", "edit.txt")
                    else:
                        self.git(item.trial, "config", "status.showUntrackedFiles", "no")
                        (item.trial / "late-file").write_text("not rehearsed\n")
                    self.assertEqual(self.git(item.trial, "status", "--porcelain"), "")

                with patch.object(self.sync.git, "commit_lock", side_effect=alter_trial):
                    with self.assertRaisesRegex(FlurryError, "Final restore rehearsal"):
                        self.run_sync(self.preserve)
                self.assertEqual(self.remote_head("a"), initial)
                self.assertEqual(self.git(self.repo, "for-each-ref", "refs/flurry/"), "")

    def assert_unchanged_push_refuses_drift(self, mutate):
        audit = self.directory / "pushed"
        hook = self.repo / ".git/hooks/pre-push"
        hook.write_text(f'#!/bin/sh\ntouch "{audit}"\n')
        hook.chmod(0o755)
        action = Journal.action

        def mutate_at_push(journal, name):
            action(journal, name)
            if name == "pushing:a":
                mutate()

        with patch.object(Journal, "action", new=mutate_at_push):
            with self.assertRaisesRegex(FlurryError, "Source changed during rehearsal"):
                self.run_sync(self.preserve)
        self.assertFalse(audit.exists())
        failed = self.journal()
        self.assertNotIn("recovery", failed["repositories"]["a"])
        self.assertEqual(self.git(self.repo, "for-each-ref", "refs/flurry/"), "")
        with self.assertRaisesRegex(FlurryError, "checkout changed"):
            self.sync.resume(load_config(self.root, ()), failed["id"])

    def test_unchanged_push_detects_edit_with_same_head(self):
        path = self.repo / "edit.txt"
        self.assert_unchanged_push_refuses_drift(lambda: path.write_text("concurrent edit\n"))
        self.assertEqual(path.read_text(), "concurrent edit\n")

    def test_unchanged_push_detects_branch_switch_with_same_head(self):
        self.assert_unchanged_push_refuses_drift(lambda: self.git(self.repo, "checkout", "-b", "other"))
        self.assertEqual(self.git(self.repo, "symbolic-ref", "HEAD"), "refs/heads/other")

    def test_collision_guard_checks_refs_created_at_the_promotion_journal_boundary(self):
        initial = self.remote_head("a")
        seed = self.repos["a"][2]
        self.git(seed, "commit", "--allow-empty", "-m", "upstream work")
        self.git(seed, "push", "origin", "HEAD:refs/heads/baseline")
        (self.root / "flurry.toml").write_text('[repositories.a]\nrebase_onto = "origin/baseline"\n')
        candidate = self.git(seed, "rev-parse", "HEAD")
        suffix = hashlib.sha256(str(self.repo).encode()).hexdigest()[:16]
        save = Journal.save

        def create_ref_after_promotion_save(journal):
            save(journal)
            if journal.document["action"] == "promoting:a" and journal.document["status"] == "running":
                recorded = json.loads(journal.path.read_text())
                self.assertEqual(recorded["repositories"]["a"]["head"], candidate)
                ref = f"refs/flurry/{journal.run_id}/{suffix}/remaining"
                self.git(self.repo, "update-ref", ref, initial)

        with patch.object(Journal, "save", new=create_ref_after_promotion_save):
            with self.assertRaisesRegex(FlurryError, "Recovery ref already exists"):
                self.run_sync(self.preserve)
        ref = f"refs/flurry/{self.journal()['id']}/{suffix}/remaining"
        self.assertEqual(self.git(self.repo, "for-each-ref", "--format=%(refname) %(objectname)", "refs/flurry/"), f"{ref} {initial}")
        self.assertEqual(self.remote_head("a"), initial)

    def test_promotion_journal_failure_aborts_before_importing_recovery_refs(self):
        _, _, seed = self.repos["a"]
        initial = self.git(self.repo, "rev-parse", "HEAD")
        (self.repo / "edit.txt").write_text("retained\n")
        self.git(seed, "commit", "--allow-empty", "-m", "upstream work")
        self.git(seed, "push", "origin", "main")
        upstream = self.remote_head("a")
        save = Journal.save

        def fail_promotion_save(journal):
            if journal.document["action"] == "promoting:a" and journal.document["status"] == "running":
                self.assertEqual(journal.document["repositories"]["a"]["head"], upstream)
                raise OSError("promotion journal write failed")
            save(journal)

        with patch.object(Journal, "save", new=fail_promotion_save):
            with self.assertRaisesRegex(FlurryError, "promotion journal write failed"):
                self.run_sync(self.preserve)
        self.assertEqual(self.git(self.repo, "rev-parse", "HEAD"), initial)
        self.assertEqual(self.git(self.repo, "for-each-ref", "refs/flurry/"), "")
        self.assertEqual(self.git(self.repo, "stash", "list"), "")
        self.assertEqual((self.repo / "edit.txt").read_text(), "retained\n")
        self.assertEqual(self.remote_head("a"), upstream)


@unittest.skipUnless(shutil.which("nix") and os.environ.get("FLURRY_REAL_NIX") != "0", "real-Nix leg explicitly disabled or Nix unavailable")
class SyncTests(SyncFixture, unittest.TestCase):
    def test_success_removes_only_current_run_refs_and_preserves_dirty_state(self):
        a = self.add_repo("a", {})
        (a / "edit.txt").write_text("existing stash\n")
        self.git(a, "stash", "push", "-m", "user stash")
        (a / "edit.txt").write_text("staged\n")
        self.git(a, "add", "edit.txt")
        (a / "edit.txt").write_text("unstaged\n")
        (a / "untracked.txt").write_text("untracked\n")
        self.git(a, "update-ref", "refs/flurry/previous/prepared", "HEAD")
        self.git(a, "update-ref", "refs/custom/keep", "HEAD")
        commands = (
            ("diff", "--cached", "--binary"), ("diff", "--binary"),
            ("stash", "list", "--format=%H"), ("ls-files", "--others", "--exclude-standard"),
            ("reflog", "show", "--format=%H %gs", "HEAD"),
        )
        before = [self.git(a, *args) for args in commands]
        refs_before = self.git(a, "for-each-ref", "--format=%(refname) %(objectname)")
        journal = self.run_sync(self.options("preserve"))
        self.assertEqual(journal.document["status"], "complete")
        self.assertEqual([self.git(a, *args) for args in commands], before)
        self.assertEqual((a / "untracked.txt").read_text(), "untracked\n")
        self.assertEqual(self.git(a, "for-each-ref", "--format=%(refname) %(objectname)"), refs_before)

    def test_success_cleans_refs_for_each_dirty_policy(self):
        a = self.add_repo("a", {})
        options = (
            self.options("reject"),
            SyncOptions("commit", "staged", "staged work", "eval", ()),
            SyncOptions("commit", "all", "all work", "eval", ()),
        )
        for option in options:
            with self.subTest(option=option):
                if option.dirty_mode == "commit":
                    (a / "edit.txt").write_text(option.commit_scope + "\n")
                    self.git(a, "add", "edit.txt")
                journal = self.run_sync(option)
                self.assertEqual(journal.document["status"], "complete")
                self.assertEqual(self.git(a, "for-each-ref", "refs/flurry/"), "")

    def test_cleanup_failure_is_reported_after_publication(self):
        a = self.add_repo("a", {})
        seed = self.repos["a"][2]
        self.git(seed, "commit", "--allow-empty", "-m", "upstream work")
        self.git(seed, "push", "origin", "main")
        with patch.object(self.sync.git, "cleanup", side_effect=FlurryError("cleanup refused")):
            with self.assertRaisesRegex(FlurryError, "cleanup refused.*\\nPublished: a"):
                self.run_sync(self.options("preserve"))
        data = json.loads(next((self.root / ".flurry" / "runs").glob("*/run.json")).read_text())
        self.assertEqual(data["status"], "failed")
        self.assertEqual(data["action"], "cleaning:a")
        self.assertEqual(data["repositories"]["a"]["state"], "published")
        self.assertEqual(len(self.git(a, "for-each-ref", "--format=%(refname)", "refs/flurry/").splitlines()), 3)

    def test_independent_preparations_overlap_before_any_publication(self):
        self.add_repo("a", {})
        self.add_repo("b", {})
        ready = threading.Barrier(2, timeout=10)
        prepare = self.sync.git.prepare
        finished = set()
        lock = threading.Lock()
        push = self.sync.git.push

        def overlapping_prepare(repo, *args, **kwargs):
            ready.wait()
            item = prepare(repo, *args, **kwargs)
            with lock:
                finished.add(repo.name)
            return item

        def checked_push(*args, **kwargs):
            self.assertEqual(finished, {"a", "b"})
            return push(*args, **kwargs)

        with patch.object(self.sync.git, "prepare", side_effect=overlapping_prepare), patch.object(self.sync.git, "push", side_effect=checked_push):
            journal = self.run_sync(self.options("preserve"))
        self.assertEqual(journal.document["status"], "complete")
        self.assertEqual(set(journal.document["repositories"]), finished)

    def test_linked_worktrees_prepare_serially(self):
        a = self.add_repo("a", {})
        b = self.root / "b"
        self.git(a, "worktree", "add", "-b", "topic", str(b))
        self.git(b, "branch", "--set-upstream-to=origin/main")
        prepare = self.sync.git.prepare
        lock = threading.Lock()
        active = 0
        maximum = 0
        started = []

        def tracked_prepare(repo, *args, **kwargs):
            nonlocal active, maximum
            with lock:
                active += 1
                maximum = max(maximum, active)
                started.append(repo.name)
            try:
                return prepare(repo, *args, **kwargs)
            finally:
                with lock:
                    active -= 1

        with patch.object(self.sync.git, "prepare", side_effect=tracked_prepare):
            self.run_sync(self.options("preserve"))
        self.assertEqual(maximum, 1)
        self.assertEqual(set(started), {"a", "b"})
        self.assertEqual(self.git(a, "for-each-ref", "refs/flurry/"), "")
        self.assertEqual(self.git(b, "for-each-ref", "refs/flurry/"), "")

    def test_preparation_concurrency_is_bounded(self):
        for name in ("a", "b", "c", "d", "e", "f"):
            self.add_repo(name, {})
        ready = threading.Barrier(4, timeout=10)
        prepare = self.sync.git.prepare
        lock = threading.Lock()
        active = 0
        maximum = 0
        started = 0

        def bounded_prepare(*args, **kwargs):
            nonlocal active, maximum, started
            with lock:
                active += 1
                maximum = max(maximum, active)
                started += 1
                initial = started <= 4
            try:
                if initial:
                    ready.wait()
                return prepare(*args, **kwargs)
            finally:
                with lock:
                    active -= 1

        with patch.object(self.sync.git, "prepare", side_effect=bounded_prepare):
            self.run_sync(self.options("preserve"))
        self.assertEqual(maximum, 4)
        self.assertEqual(started, 6)

    def test_preparation_failure_drains_workers_without_promotion_or_publication(self):
        self.add_repo("a", {})
        self.add_repo("b", {})
        before = {name: self.remote_head(name) for name in self.repos}
        ready = threading.Barrier(2, timeout=10)
        failed = threading.Event()
        finished = threading.Event()
        prepare = self.sync.git.prepare

        def failing_prepare(repo, *args, **kwargs):
            ready.wait()
            if repo.name == "a":
                failed.set()
                raise FlurryError("preparation-refused")
            self.assertTrue(failed.wait(timeout=10))
            try:
                return prepare(repo, *args, **kwargs)
            finally:
                finished.set()

        with patch.object(self.sync.git, "prepare", side_effect=failing_prepare), patch.object(self.sync.git, "promote") as promote, patch.object(self.sync.git, "push") as push:
            with self.assertRaisesRegex(FlurryError, "preparation-refused"):
                self.run_sync(self.options("preserve"))
            self.assertTrue(finished.is_set(), "Workers must finish before releasing the workspace")
            promote.assert_not_called()
            push.assert_not_called()
        for name, (repo, _, _) in self.repos.items():
            self.assertEqual(self.remote_head(name), before[name])
            self.assertEqual(self.git(repo, "rev-parse", "HEAD"), before[name])
            self.assertEqual(self.git(repo, "status", "--porcelain"), "")
        journal = next((self.root / ".flurry" / "runs").glob("*/run.json"))
        self.assertEqual(json.loads(journal.read_text())["status"], "failed")

    def test_real_nix_cascade_publishes_locks_preserving_user_edits_and_is_idempotent(self):
        a = self.add_repo("a", {})
        b = self.add_repo("b", {"a": "a"})
        c = self.add_repo("c", {"a": "a", "b": "b"})
        old_b = self.remote_head("b")
        (a / "feature.txt").write_text("committed provider feature\n")
        self.git(a, "add", "feature.txt")
        self.git(a, "commit", "-m", "provider feature")
        (a / "edit.txt").write_text("base\nstaged\n")
        self.git(a, "add", "edit.txt")
        (a / "edit.txt").write_text("base\nstaged\nunstaged\n")
        (a / "untracked.txt").write_text("never publish this\n")
        staged = self.git(a, "diff", "--cached", "--binary")
        unstaged = self.git(a, "diff", "--binary")
        result = self.run_sync(self.options("preserve"))
        self.assertEqual(result.document["status"], "complete")
        repositories = result.document["repositories"]
        self.assertEqual({name for name, entry in repositories.items() if "recovery" in entry}, {"b", "c"})
        self.assertNotEqual(old_b, self.remote_head("b"))
        self.assertEqual(self.nix.locked_inputs(b)["a"].rev, self.remote_head("a"))
        self.assertEqual(self.nix.locked_inputs(c)["a"].rev, self.remote_head("a"))
        self.assertEqual(self.nix.locked_inputs(c)["b"].rev, self.remote_head("b"))
        self.assertEqual(self.git(a, "diff", "--cached", "--binary"), staged)
        self.assertEqual(self.git(a, "diff", "--binary"), unstaged)
        self.assertEqual((a / "untracked.txt").read_text(), "never publish this\n")
        published = self.git(self.repos["a"][1], "ls-tree", "-r", "--name-only", "main")
        self.assertNotIn("untracked.txt", published)
        heads = [self.remote_head(name) for name in ("a", "b", "c")]
        unchanged = self.run_sync(self.options("preserve"))
        for entry in unchanged.document["repositories"].values():
            self.assertNotIn("recovery", entry)
        self.assertEqual(heads, [self.remote_head(name) for name in ("a", "b", "c")])

    def test_checks_none_still_runs_consumer_commit_hook_before_publishing_lock(self):
        a = self.add_repo("a", {})
        b = self.add_repo("b", {"a": "a"})
        old_b = self.remote_head("b")
        (a / "feature").write_text("provider change\n")
        self.git(a, "add", "feature")
        self.git(a, "commit", "-m", "provider change")
        (b / "edit.txt").write_text("private consumer edit\n")
        audit = self.directory / "hook-context"
        hook = b / ".git/hooks/pre-commit"
        hook.write_text('#!/bin/sh\nset -eu\n'
                        f'git rev-parse --show-toplevel > "{audit}"\n'
                        f'git diff --cached --name-only >> "{audit}"\n')
        hook.chmod(0o755)
        options = SyncOptions("preserve", None, None, "none", ())
        self.assertEqual(self.run_sync(options).document["status"], "complete")
        context, paths = audit.read_text().splitlines()
        self.assertNotEqual(Path(context), b)
        self.assertEqual(paths, "flake.lock")
        self.assertNotEqual(old_b, self.remote_head("b"))
        self.assertEqual(self.nix.locked_inputs(b)["a"].rev, self.remote_head("a"))
        self.assertEqual((b / "edit.txt").read_text(), "private consumer edit\n")
        self.assertEqual(self.git(self.repos["b"][1], "show", "main:edit.txt"), "base")

    def test_checks_none_does_not_publish_consumer_rejected_by_commit_hook(self):
        a = self.add_repo("a", {})
        b = self.add_repo("b", {"a": "a"})
        old_b = self.remote_head("b")
        (a / "feature").write_text("provider change\n")
        self.git(a, "add", "feature")
        self.git(a, "commit", "-m", "provider change")
        (b / "edit.txt").write_text("private consumer edit\n")
        audit = self.directory / "hook-rejection"
        hook = b / ".git/hooks/pre-commit"
        hook.write_text('#!/bin/sh\nset -eu\n'
                        f'git diff --cached --name-only > "{audit}"\n'
                        'printf "policy-refused\\n" >&2\nexit 1\n')
        hook.chmod(0o755)
        options = SyncOptions("preserve", None, None, "none", ())
        with self.assertRaisesRegex(FlurryError, "policy-refused"):
            self.run_sync(options)
        self.assertEqual(audit.read_text().strip(), "flake.lock")
        self.assertEqual(self.remote_head("a"), self.git(a, "rev-parse", "HEAD"))
        self.assertEqual(self.remote_head("b"), old_b)
        self.assertEqual(self.git(b, "rev-parse", "HEAD"), old_b)
        self.assertEqual((b / "edit.txt").read_text(), "private consumer edit\n")

    def test_failed_check_reports_and_retains_reproduction_without_publishing(self):
        repo = self.add_repo("a", {})
        before = self.remote_head("a")
        declaration = repo / "flake.nix"
        declaration.write_text('{ outputs = _: throw "check-refused https://token@forge.example/x"; }')
        self.git(repo, "add", "flake.nix")
        self.git(repo, "commit", "-m", "failing check fixture")
        with self.assertRaises(FlurryError) as error:
            self.run_sync(self.options("preserve"))
        reports = [event for event in self.events if event.startswith("Checking: ")]
        self.assertEqual(len(reports), 1)
        command = reports[0].removeprefix("Checking: ")
        tokens = shlex.split(command)
        self.assertEqual(tokens[0], "cd")
        trial = Path(tokens[1])
        self.assertTrue(trial.is_dir(), "Failure must retain the check working directory")
        self.assertNotEqual(trial, repo)
        self.assertEqual(tokens[2:4], ["&&", "nix"])
        self.assertIn(command, str(error.exception))
        journal = next((self.root / ".flurry" / "runs").glob("*/run.json"))
        data = json.loads(journal.read_text())
        self.assertEqual(data["status"], "failed")
        self.assertIn(command, data["detail"])
        self.assertIn("check-refused", data["detail"])
        self.assertNotIn("token@", str(error.exception) + journal.read_text() + reports[0])
        self.assertEqual(self.remote_head("a"), before)

    def test_cli_check_progress_keeps_json_stdout_pure(self):
        self.add_repo("a", {})
        output, errors = io.StringIO(), io.StringIO()
        with patch.dict(os.environ, self.env), contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            result = main(["sync", "--preserve", "--json", "--color=always", "--root", str(self.root)])
        self.assertEqual(result, 0, errors.getvalue())
        self.assertEqual(json.loads(output.getvalue())["status"], "complete")
        self.assertNotIn("Checking:", output.getvalue())
        self.assertIn("Checking: cd ", errors.getvalue())
        self.assertIn("--option accept-flake-config false", errors.getvalue())
        self.assertIn("--option allow-import-from-derivation false", errors.getvalue())
        self.assertIn("flake check --no-write-lock-file --no-build", errors.getvalue())
        self.assertNotIn("\x1b", output.getvalue() + errors.getvalue())

    def test_new_lock_is_git_visible_to_the_validation_gate(self):
        self.add_repo("a", {})
        b = self.add_repo("b", {"a": "a"})
        self.git(b, "rm", "flake.lock")
        self.git(b, "commit", "-m", "defer initial lock")

        class TrackingNix(Nix):
            def check(inner, path, full, *, report):
                if (path / "flake.lock").exists():
                    result = inner.runner.call(["git", "-C", str(path), "ls-files", "--error-unmatch", "flake.lock"], None, None, {}, False)
                    if result.returncode:
                        raise FlurryError("Generated flake.lock must be Git-visible before validation")
                super().check(path, full, report=report)

        gate = TrackingNix(self.runner)
        service = Sync(self.runner, gate, Git(self.runner), self.events.append)
        service.run(load_config(self.root, ()), self.options("preserve"), None)
        self.assertEqual(self.nix.locked_inputs(b)["a"].rev, self.remote_head("a"))

    def test_local_worktree_input_edge_survives_isolated_rehearsal(self):
        a = self.add_repo("a", {})
        b = self.add_repo("b", {"a": "a"})
        declaration = b / "flake.nix"
        declaration.write_text(declaration.read_text().replace(self.origins.joinpath("a.git").as_uri(), a.as_uri()))
        self.git(b, "add", "flake.nix")
        self.nix.update(b, ("a",))
        self.git(b, "add", "flake.lock")
        self.git(b, "commit", "-m", "Use local Git provider")
        previous = self.nix.locked_inputs(b)["a"].rev
        (a / "feature.txt").write_text("new provider commit\n")
        self.git(a, "add", "feature.txt")
        self.git(a, "commit", "-m", "provider feature")
        self.run_sync(self.options("preserve"))
        self.assertNotEqual(previous, self.remote_head("a"))
        self.assertEqual(self.nix.locked_inputs(b)["a"].rev, self.remote_head("a"))

    def test_input_branch_mismatch_fails_before_source_promotion(self):
        a = self.add_repo("a", {})
        self.add_repo("b", {"a": "a"})
        self.git(a, "checkout", "-b", "topic")
        (self.root / "flurry.toml").write_text('[repositories.a]\nrebase_onto = "origin/main"\n')
        before = self.git(a, "rev-parse", "HEAD")
        with self.assertRaisesRegex(FlurryError, "tracks refs/heads/main"):
            self.run_sync(self.options("preserve"))
        self.assertEqual(before, self.git(a, "rev-parse", "HEAD"))
        self.assertEqual(before, self.remote_head("a"))

    def test_commit_all_publishes_user_work_before_lock_cascade(self):
        a = self.add_repo("a", {})
        b = self.add_repo("b", {"a": "a"})
        (a / "feature.txt").write_text("new user file\n")
        options = SyncOptions("commit", "all", "User requested work", "eval", ())
        self.run_sync(options)
        self.assertEqual(self.git(a, "status", "--porcelain"), "")
        self.assertIn("feature.txt", self.git(self.repos["a"][1], "ls-tree", "-r", "--name-only", "main"))
        self.assertEqual(self.nix.locked_inputs(b)["a"].rev, self.remote_head("a"))

    def test_rebase_override_does_not_redirect_the_default_push_remote(self):
        a = self.add_repo("a", {})
        self.git(a, "remote", "add", "upstream", self.repos["a"][1].as_uri())
        (self.root / "flurry.toml").write_text('[repositories.a]\nrebase_onto = "upstream/main"\n')
        result = plan_sync(load_config(self.root, ()), self.runner, self.nix, self.options("preserve"))
        self.assertEqual(result.targets[0].remote, "upstream")
        self.assertEqual(result.targets[0].push_remote, "origin")

    def test_rebase_remote_credentials_are_rejected_by_offline_plan(self):
        a = self.add_repo("a", {})
        self.git(a, "remote", "add", "baseline", "https://token@forge.example/team/a.git")
        (self.root / "flurry.toml").write_text('[repositories.a]\nrebase_onto = "baseline/main"\npush_remote = "origin"\n')
        with self.assertRaisesRegex(FlurryError, "Credentials"):
            plan_sync(load_config(self.root, ()), self.runner, self.nix, self.options("preserve"))

    def test_excluded_provider_is_not_pushed_or_advanced(self):
        a = self.add_repo("a", {})
        b = self.add_repo("b", {"a": "a"})
        locked = self.nix.locked_inputs(b)["a"].rev
        (a / "new.txt").write_text("local only\n")
        self.git(a, "add", "new.txt")
        self.git(a, "commit", "-m", "not selected")
        options = SyncOptions("preserve", None, None, "eval", ("a",))
        self.run_sync(options)
        self.assertEqual(self.remote_head("a"), locked)
        self.assertEqual(self.nix.locked_inputs(b)["a"].rev, locked)

    def test_excluded_configured_source_alias_is_frozen_transitively(self):
        a = self.add_repo("a", {})
        self.add_repo("b", {"a": "a"})
        self.add_repo("c", {"b": "b"})
        canonical = self.repos["a"][1].as_uri()
        fork = self.origins / "fork.git"
        self.runner.run(["git", "clone", "--bare", canonical, str(fork)], None)
        self.git(a, "remote", "set-url", "origin", fork.as_uri())
        (self.root / "flurry.toml").write_text(f'[repositories.a]\nsource = "git+{canonical}"\n')
        seed_a = self.repos["a"][2]
        (seed_a / "feature.txt").write_text("new canonical version\n")
        self.git(seed_a, "add", "feature.txt")
        self.git(seed_a, "commit", "-m", "canonical feature")
        self.git(seed_a, "push", "origin", "main")
        seed_b = self.repos["b"][2]
        self.nix.update(seed_b, ("a",))
        self.git(seed_b, "add", "flake.lock")
        self.git(seed_b, "commit", "-m", "advance transitive frozen provider")
        self.git(seed_b, "push", "origin", "main")
        original_a = self.git(a, "rev-parse", "HEAD")
        original_c = self.remote_head("c")
        with self.assertRaisesRegex(FlurryError, "excluded provider boundary"):
            self.run_sync(SyncOptions("preserve", None, None, "eval", ("a",)))
        self.assertEqual(original_a, self.git(a, "rev-parse", "HEAD"))
        self.assertEqual(original_c, self.remote_head("c"))

    def test_dirty_lock_is_rejected_without_publishing_anything(self):
        a = self.add_repo("a", {})
        b = self.add_repo("b", {"a": "a"})
        before = {name: self.remote_head(name) for name in ("a", "b")}
        (b / "flake.lock").write_text((b / "flake.lock").read_text() + "\n")
        with self.assertRaisesRegex(FlurryError, "pre-existing flake"):
            self.run_sync(self.options("preserve"))
        self.assertEqual(before, {name: self.remote_head(name) for name in before})

    def test_rebase_conflict_is_rehearsed_before_any_push(self):
        a = self.add_repo("a", {})
        b = self.add_repo("b", {"a": "a"})
        (a / "edit.txt").write_text("local conflicting commit\n")
        self.git(a, "add", "edit.txt")
        self.git(a, "commit", "-m", "local")
        seed = self.repos["a"][2]
        (seed / "edit.txt").write_text("remote conflicting commit\n")
        self.git(seed, "add", "edit.txt")
        self.git(seed, "commit", "-m", "remote")
        self.git(seed, "push", "origin", "main")
        heads = {name: self.git(self.repos[name][0], "rev-parse", "HEAD") for name in ("a", "b")}
        remote_b = self.remote_head("b")
        with self.assertRaisesRegex(FlurryError, "Rebase rehearsal failed"):
            self.run_sync(self.options("preserve"))
        self.assertEqual(heads, {name: self.git(self.repos[name][0], "rev-parse", "HEAD") for name in heads})
        self.assertEqual(remote_b, self.remote_head("b"))

    def test_push_failure_retains_journal_and_resume_revalidates(self):
        a = self.add_repo("a", {})
        self.add_repo("b", {"a": "a"})
        hook = self.repos["b"][1] / "hooks" / "pre-receive"
        hook.write_text("#!/bin/sh\nexit 1\n")
        hook.chmod(0o755)
        (a / "feature.txt").write_text("provider feature\n")
        self.git(a, "add", "feature.txt")
        self.git(a, "commit", "-m", "feature")
        with self.assertRaisesRegex(FlurryError, "Published: a"):
            self.run_sync(self.options("preserve"))
        journals = list((self.root / ".flurry" / "runs").glob("*/run.json"))
        self.assertEqual(len(journals), 1)
        data = json.loads(journals[0].read_text())
        self.assertEqual(data["status"], "failed")
        self.assertEqual(data["repositories"]["a"]["state"], "published")
        retained = {}
        for name, (repo, _, _) in self.repos.items():
            refs = self.git(repo, "for-each-ref", "--format=%(refname) %(objectname)", "refs/flurry/")
            self.assertEqual(len(refs.splitlines()), 3 if name == "b" else 0)
            retained[name] = refs
        hook.unlink()
        resumed = self.sync.resume(load_config(self.root, ()), data["id"])
        self.assertEqual(resumed.document["status"], "complete")
        for name, (repo, _, _) in self.repos.items():
            self.assertEqual(self.git(repo, "for-each-ref", "--format=%(refname) %(objectname)", "refs/flurry/"), retained[name])
        self.assertEqual(self.nix.locked_inputs(self.repos["b"][0])["a"].rev, self.remote_head("a"))

    def test_new_repository_after_failure_is_not_silently_enrolled_by_resume(self):
        a = self.add_repo("a", {})
        hook = self.repos["a"][1] / "hooks" / "pre-receive"
        hook.write_text("#!/bin/sh\nexit 1\n")
        hook.chmod(0o755)
        (a / "feature.txt").write_text("provider feature\n")
        self.git(a, "add", "feature.txt")
        self.git(a, "commit", "-m", "feature")
        with self.assertRaises(FlurryError):
            self.run_sync(self.options("preserve"))
        journal = next((self.root / ".flurry" / "runs").glob("*/run.json"))
        data = json.loads(journal.read_text())
        new = self.add_repo("new", {})
        original = self.remote_head("new")
        (new / "feature.txt").write_text("not authorized by the old run\n")
        self.git(new, "add", "feature.txt")
        self.git(new, "commit", "-m", "new work")
        hook.unlink()
        with self.assertRaisesRegex(FlurryError, "inventory changed"):
            self.sync.resume(load_config(self.root, ()), data["id"])
        self.assertEqual(original, self.remote_head("new"))

    def test_preserved_edit_after_failure_blocks_resume(self):
        a = self.add_repo("a", {})
        hook = self.repos["a"][1] / "hooks" / "pre-receive"
        hook.write_text("#!/bin/sh\nexit 1\n")
        hook.chmod(0o755)
        (a / "new.txt").write_text("committed\n")
        self.git(a, "add", "new.txt")
        self.git(a, "commit", "-m", "new")
        with self.assertRaises(FlurryError):
            self.run_sync(self.options("preserve"))
        journal = next((self.root / ".flurry" / "runs").glob("*/run.json"))
        (a / "edit.txt").write_text("concurrent user change\n")
        with self.assertRaisesRegex(FlurryError, "checkout changed"):
            self.sync.resume(load_config(self.root, ()), json.loads(journal.read_text())["id"])
