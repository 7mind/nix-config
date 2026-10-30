"""Effectual-GoodCommunication: private state and disposable real Git worktrees."""
import fcntl
import os
from pathlib import Path
import tempfile
import unittest

from flurry.process import FlurryError, Runner
from flurry.state import workspace_lock


class StateIgnoreTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="flurry-state-ignore-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.repo = self.root / "repository"
        self.runner = Runner(os.environ | {
            "HOME": str(self.root), "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
            "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
        }, 10)
        self.runner.run(["git", "init", "--initial-branch=main", str(self.repo)], None)
        (self.repo / ".gitignore").write_text("# project rules\nbuild/\n")
        (self.repo / "tracked").write_text("base\n")
        self.git("add", ".")
        self.git("commit", "-m", "initial")

    def git(self, *args):
        return self.runner.git(self.repo, *args)

    def lock(self, root):
        return workspace_lock(root, self.runner)

    def ignored(self, path):
        result = self.runner.call(["git", "-C", str(self.repo), "check-ignore", "--quiet", "--", str(path) + "/"],
                                  None, None, {}, False)
        self.assertIn(result.returncode, (0, 1))
        return result.returncode == 0

    def test_new_and_existing_state_is_ignored_without_dirtying_tracked_files(self):
        (self.repo / "tracked").write_text("staged\n")
        self.git("add", "tracked")
        (self.repo / "tracked").write_text("staged\nunstaged\n")
        before = (self.git("diff", "--cached", "--binary"), self.git("diff", "--binary"))
        ignore = (self.repo / ".gitignore").read_bytes()
        exclude = self.repo / ".git/info/exclude"
        exclude.write_bytes(b"# keep this comment\nexisting-rule")
        exclude.chmod(0o640)
        with self.lock(self.repo):
            (self.repo / ".flurry/private-journal").write_text("private state\n")
            self.assertTrue(self.ignored(self.repo / ".flurry"))
        first = exclude.read_bytes()
        with self.lock(self.repo):
            self.assertTrue(self.ignored(self.repo / ".flurry"))
        self.assertEqual(exclude.read_bytes(), first)
        self.assertTrue(first.startswith(b"# keep this comment\nexisting-rule\n"))
        self.assertEqual(exclude.stat().st_mode & 0o777, 0o640)
        self.assertEqual((self.repo / ".gitignore").read_bytes(), ignore)
        self.assertEqual((self.git("diff", "--cached", "--binary"), self.git("diff", "--binary")), before)
        self.assertNotIn(b".flurry", self.git("status", "--porcelain"))

    def test_nested_workspace_pattern_is_literal_and_path_scoped(self):
        workspace = self.repo / "nested [*?] \\ workspace"
        workspace.mkdir()
        with self.lock(workspace):
            self.assertTrue(self.ignored(workspace / ".flurry"))
        other = self.repo / ".flurry"
        other.mkdir()
        self.assertFalse(self.ignored(other))

    def test_linked_worktree_uses_git_resolved_exclude_file(self):
        linked = self.root / "linked checkout"
        self.git("worktree", "add", "-b", "linked", str(linked))
        with self.lock(linked):
            result = self.runner.call(["git", "-C", str(linked), "check-ignore", "--quiet", "--", ".flurry/"],
                                      None, None, {}, False)
            self.assertEqual(result.returncode, 0)
        self.assertEqual(self.runner.git(linked, "status", "--porcelain"), b"")

    def test_existing_ignore_rule_needs_no_metadata_edit(self):
        (self.repo / ".gitignore").write_text(".flurry/\n")
        exclude = self.repo / ".git/info/exclude"
        before = exclude.read_bytes()
        with self.lock(self.repo):
            self.assertTrue(self.ignored(self.repo / ".flurry"))
        self.assertEqual(exclude.read_bytes(), before)

    def test_tracked_state_is_not_silently_removed_from_index(self):
        directory = self.repo / ".flurry"
        directory.mkdir()
        (directory / "tracked-state").write_text("existing\n")
        self.git("add", ".flurry")
        self.git("commit", "-m", "existing state")
        before = self.git("ls-files", "--stage", "-z")
        with self.assertRaisesRegex(FlurryError, "already tracked"):
            with self.lock(self.repo):
                self.fail("Tracked state accepted")
        self.assertEqual(self.git("ls-files", "--stage", "-z"), before)

    def test_higher_priority_unignore_is_not_silently_accepted(self):
        ignore = self.repo / ".gitignore"
        ignore.write_text("!/.flurry/\n!/.flurry/**\n")
        before = ignore.read_bytes()
        with self.assertRaisesRegex(FlurryError, "not ignored"):
            with self.lock(self.repo):
                self.fail("Explicitly unignored state accepted")
        self.assertEqual(ignore.read_bytes(), before)

    def test_symlink_exclude_is_not_written_through(self):
        target = self.root / "exclude-target"
        target.write_bytes(b"keep\n")
        exclude = self.repo / ".git/info/exclude"
        exclude.unlink()
        exclude.symlink_to(target)
        with self.assertRaises(FlurryError):
            with self.lock(self.repo):
                self.fail("Symlink exclude accepted")
        self.assertEqual(target.read_bytes(), b"keep\n")

    def test_symlink_info_directory_is_not_written_through(self):
        info = self.repo / ".git/info"
        target = self.root / "external-info"
        info.rename(target)
        info.symlink_to(target, target_is_directory=True)
        before = (target / "exclude").read_bytes()
        with self.assertRaises(FlurryError):
            with self.lock(self.repo):
                self.fail("Symlink info directory accepted")
        self.assertEqual((target / "exclude").read_bytes(), before)

    def test_missing_exclude_file_and_directory_are_created(self):
        info = self.repo / ".git/info"
        (info / "exclude").unlink()
        info.rmdir()
        with self.lock(self.repo):
            self.assertTrue(self.ignored(self.repo / ".flurry"))
        self.assertTrue((info / "exclude").is_file())

    def test_shared_exclude_lock_contention_refuses_without_writing(self):
        exclude = self.repo / ".git/info/exclude"
        before = exclude.read_bytes()
        with exclude.open("r+b") as held:
            fcntl.flock(held.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaisesRegex(FlurryError, "Cannot update Git exclusion"):
                with self.lock(self.repo):
                    self.fail("Contended exclude lock accepted")
        self.assertEqual(exclude.read_bytes(), before)

    def test_non_git_workspace_needs_no_git_metadata(self):
        workspace = self.root / "plain workspace"
        workspace.mkdir()
        with self.lock(workspace):
            self.assertTrue((workspace / ".flurry/workspace.lock").is_file())
        self.assertFalse((workspace / ".gitignore").exists())
