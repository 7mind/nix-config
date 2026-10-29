import os
import tempfile
import unittest
from pathlib import Path

from flurry.process import FlurryError, Runner
from flurry.state import Journal, config_digest, fingerprint, load_journal, workspace_lock


class StateTests(unittest.TestCase):
    def test_journal_is_private_durable_and_root_bound(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with workspace_lock(root):
                journal = Journal(root, {"mode": "preserve"})
                journal.repository("a", {"state": "published", "head": "abc"})
                journal.finish("complete", "done")
                data = load_journal(root, journal.run_id)
                self.assertEqual(data["status"], "complete")
                self.assertEqual(data["repositories"]["a"]["head"], "abc")
                self.assertEqual(journal.path.stat().st_mode & 0o777, 0o600)
                self.assertEqual(journal.directory.stat().st_mode & 0o777, 0o700)
                self.assertFalse((journal.directory / "run.json.new").exists())

    def test_second_operation_cannot_take_workspace_lock(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with workspace_lock(root):
                with self.assertRaisesRegex(FlurryError, "Another flurry"):
                    with workspace_lock(root):
                        self.fail("Concurrent operation admitted")

    def test_symlink_state_directory_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            elsewhere = root / "elsewhere"
            elsewhere.mkdir()
            (root / ".flurry").symlink_to(elsewhere, target_is_directory=True)
            with self.assertRaisesRegex(FlurryError, "symlink"):
                with workspace_lock(root):
                    pass
            self.assertEqual(list(elsewhere.iterdir()), [])

    def test_changed_config_has_different_digest(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            before = config_digest(root)
            (root / "flurry.toml").write_text('version = 1\nexclude = ["a"]\n')
            self.assertNotEqual(before, config_digest(root))

    def test_resume_fingerprint_detects_untracked_mode_and_kind_changes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runner = Runner(os.environ | {"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
                                         "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
                                         "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid"}, 10)
            runner.run(["git", "init", "--initial-branch=main", str(root)], None)
            runner.git(root, "commit", "--allow-empty", "-m", "initial")
            path = root / "untracked"
            path.write_text("target")
            before = fingerprint(root, runner)
            path.chmod(0o755)
            self.assertNotEqual(before, fingerprint(root, runner))
            path.chmod(0o644)
            path.unlink()
            path.symlink_to("target")
            self.assertNotEqual(before, fingerprint(root, runner))

    def test_journal_identifier_cannot_escape_state_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(FlurryError, "Invalid run ID"):
                load_journal(Path(temporary), "../../outside")
