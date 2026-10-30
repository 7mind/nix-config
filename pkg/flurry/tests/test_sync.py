"""Effectual-GoodCommunication: actual Git and Nix, temporary file-only remotes."""
import contextlib
import io
import json
import os
import shlex
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from flurry.cli import main
from flurry.git import Git
from flurry.nix import Nix
from flurry.process import FlurryError, Runner
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


@unittest.skipUnless(shutil.which("nix") and os.environ.get("FLURRY_REAL_NIX") != "0", "real-Nix leg explicitly disabled or Nix unavailable")
class SyncTests(unittest.TestCase):
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

    def add_repo(self, name, dependencies):
        origin = self.origins / (name + ".git")
        seed = self.seeds / name
        self.runner.run(["git", "init", "--bare", "--initial-branch=main", str(origin)], None)
        self.runner.run(["git", "init", "--initial-branch=main", str(seed)], None)
        inputs = "\n".join(f'  inputs.{key}.url = "git+{self.origins.joinpath(provider + ".git").as_uri()}?ref=main";' for key, provider in dependencies.items())
        args = ", ".join(["self", *dependencies])
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
        self.run_sync(self.options("preserve"))
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
        hook.unlink()
        resumed = self.sync.resume(load_config(self.root, ()), data["id"])
        self.assertEqual(resumed.document["status"], "complete")
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
