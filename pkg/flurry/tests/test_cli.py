import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from flurry.cli import main, parser


class CliTests(unittest.TestCase):
    def test_exclusions_before_and_after_command_are_additive(self):
        args = parser().parse_args(["--exclude", "one", "sync", "--exclude", "two", "--preserve"])
        self.assertEqual(args.global_excludes + args.exclude, ["one", "two"])
        self.assertTrue(args.preserve)

    def test_without_committing_alias_preserves_existing_edits(self):
        args = parser().parse_args(["sync", "--without-committing"])
        self.assertTrue(args.preserve)
        self.assertIsNone(args.commit)

    def test_help_needs_no_git_nix_or_authentication(self):
        with tempfile.TemporaryDirectory() as temporary:
            result = subprocess.run([sys.executable, "-m", "flurry", "--help"],
                                    env=os.environ | {"PATH": temporary}, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("pull", result.stdout)
            self.assertIn("resume", result.stdout)
            self.assertEqual(list(Path(temporary).iterdir()), [])

    def test_empty_workspace_status_and_graph_do_not_create_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for command in ("status", "graph"):
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    status = main([command, "--root", temporary, "--json"])
                self.assertEqual(status, 0)
                json.loads(output.getvalue())
                self.assertFalse((root / ".flurry").exists())

    def test_unknown_config_keys_fail_without_state_creation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "flurry.toml").write_text("version = 1\ntyop = true\n")
            errors = io.StringIO()
            with contextlib.redirect_stderr(errors):
                result = main(["status", "--root", temporary])
            self.assertEqual(result, 1)
            self.assertIn("Unknown configuration", errors.getvalue())
            self.assertFalse((root / ".flurry").exists())

    def test_nonpositive_timeout_is_rejected(self):
        errors = io.StringIO()
        with contextlib.redirect_stderr(errors):
            result = main(["status", "--timeout", "0"])
        self.assertEqual(result, 1)
        self.assertIn("positive", errors.getvalue())
