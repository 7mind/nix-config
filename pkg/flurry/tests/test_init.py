import contextlib
import io
import json
import os
import stat
import subprocess
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path
from unittest.mock import patch

from flurry.cli import main
from flurry.workspace import load_config


class InitTests(unittest.TestCase):
    def invoke(self, arguments):
        output = io.StringIO()
        errors = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            result = main(arguments)
        return result, output.getvalue(), errors.getvalue()

    def test_default_config_loads_and_only_creates_private_config(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result, output, errors = self.invoke(["init", "--root", temporary, "--json"])
            self.assertEqual(result, 0, errors)
            path = root / "flurry.toml"
            self.assertEqual(json.loads(output), {"path": str(path)})
            self.assertEqual(tomllib.loads(path.read_text()), {"version": 1, "exclude": [], "gitlab_hosts": []})
            config = load_config(root, ())
            self.assertEqual(config.excludes, ())
            self.assertEqual(config.repositories, ())
            self.assertEqual(config.gitlab_hosts, ())
            self.assertIn("flurry.local.toml", path.read_text())
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(list(root.iterdir()), [path])

    def test_exclusions_before_and_after_command_are_written_and_escaped(self):
        with tempfile.TemporaryDirectory() as temporary:
            patterns = ['scratch-*', 'quoted"*', 'unicodé-*']
            result, output, errors = self.invoke([
                "--root", temporary, "--exclude", patterns[0], "init",
                "--exclude", patterns[1], "--exclude", patterns[2], "--exclude", patterns[0],
            ])
            self.assertEqual(result, 0, errors)
            path = Path(temporary) / "flurry.toml"
            self.assertIn(str(path), output)
            self.assertEqual(load_config(Path(temporary), ()).excludes, tuple(patterns))

    def test_refuses_existing_config_without_parsing_or_changing_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "flurry.toml"
            original = b"not valid TOML\x00\xff"
            path.write_bytes(original)
            result, output, errors = self.invoke(["init", "--root", temporary])
            self.assertEqual(result, 1)
            self.assertIn("overwrite", errors)
            self.assertIn(str(path), errors)
            self.assertEqual(output, "")
            self.assertEqual(path.read_bytes(), original)
            self.assertFalse((root / ".flurry").exists())

    def test_refuses_existing_and_dangling_symlinks(self):
        for existing in (True, False):
            with self.subTest(existing=existing), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                target = root / "target"
                if existing:
                    target.write_bytes(b"unchanged")
                path = root / "flurry.toml"
                path.symlink_to(target.name)
                result, output, errors = self.invoke(["init", "--root", temporary])
                self.assertEqual(result, 1)
                self.assertIn("overwrite", errors)
                self.assertEqual(output, "")
                self.assertTrue(path.is_symlink())
                self.assertEqual(path.readlink(), Path(target.name))
                self.assertEqual(target.exists(), existing)
                if existing:
                    self.assertEqual(target.read_bytes(), b"unchanged")
                self.assertFalse((root / ".flurry").exists())

    def test_refuses_existing_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "flurry.toml"
            path.mkdir()
            result, output, errors = self.invoke(["init", "--root", temporary])
            self.assertEqual(result, 1)
            self.assertIn("overwrite", errors)
            self.assertEqual(output, "")
            self.assertTrue(path.is_dir())
            self.assertEqual(list(path.iterdir()), [])

    def test_current_directory_default_without_git_nix_or_authentication(self):
        with tempfile.TemporaryDirectory() as temporary:
            package = str(Path(__file__).resolve().parents[1])
            result = subprocess.run(
                [sys.executable, "-m", "flurry", "init"], cwd=temporary,
                env={"PATH": temporary, "PYTHONPATH": package}, text=True, capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            path = Path(temporary) / "flurry.toml"
            self.assertIn(str(path), result.stdout)
            self.assertEqual(list(Path(temporary).iterdir()), [path])

    def test_invalid_exclusion_fails_before_creating_config(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, output, errors = self.invoke(["init", "--root", temporary, "--exclude", "../other"])
            self.assertEqual(result, 1)
            self.assertIn("workspace-relative", errors)
            self.assertEqual(output, "")
            self.assertEqual(list(Path(temporary).iterdir()), [])

    def test_unencodable_exclusion_fails_before_creating_config(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, output, errors = self.invoke(["init", "--root", temporary, "--exclude", "surrogate-\ud800"])
            self.assertEqual(result, 1)
            self.assertIn("encode", errors)
            self.assertEqual(output, "")
            self.assertEqual(list(Path(temporary).iterdir()), [])

    def test_fsync_failure_reports_retained_file_and_no_success(self):
        with tempfile.TemporaryDirectory() as temporary:
            with patch("flurry.workspace.os.fsync", side_effect=OSError("test sync failure")):
                result, output, errors = self.invoke(["init", "--root", temporary])
            path = Path(temporary) / "flurry.toml"
            self.assertEqual(result, 1)
            self.assertEqual(output, "")
            self.assertIn("test sync failure", errors)
            self.assertIn("inspect it before retrying", errors)
            self.assertTrue(path.is_file())
            self.assertFalse((Path(temporary) / ".flurry").exists())

    def test_invalid_local_override_is_not_parsed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            local = root / "flurry.local.toml"
            local.write_bytes(b"invalid TOML\x00")
            result, output, errors = self.invoke(["init", "--root", temporary])
            self.assertEqual(result, 0, errors)
            self.assertEqual(local.read_bytes(), b"invalid TOML\x00")
            self.assertEqual(set(root.iterdir()), {root / "flurry.toml", local})

    def test_root_must_already_be_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "missing"
            result, output, errors = self.invoke(["init", "--root", str(root)])
            self.assertEqual(result, 1)
            self.assertIn("not a directory", errors)
            self.assertEqual(output, "")
            self.assertFalse(root.exists())
