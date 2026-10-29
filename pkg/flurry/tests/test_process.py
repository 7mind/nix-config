import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

from flurry.process import FlurryError, Runner, redact


class ProcessTests(unittest.TestCase):
    def test_redacts_url_credentials_including_token_only_userinfo(self):
        self.assertEqual(redact("https://secret@forge.example/x"), "https://[redacted]@forge.example/x")
        self.assertEqual(redact("https://user:secret@forge.example/x"), "https://[redacted]@forge.example/x")

    def test_arguments_are_not_shell_evaluated(self):
        runner = Runner(os.environ, 10)
        result = runner.text([sys.executable, "-c", "import sys;print(sys.argv[1])", "$(exit 7)"], None)
        self.assertEqual(result, "$(exit 7)")

    def test_failed_command_is_an_error_and_credentials_are_redacted(self):
        runner = Runner(os.environ, 10)
        with self.assertRaises(FlurryError) as error:
            runner.run([sys.executable, "-c", "import sys;sys.stderr.write('https://token@forge.example/x');sys.exit(3)"], None)
        self.assertNotIn("token@", str(error.exception))
        self.assertIn("(3)", str(error.exception))

    def test_ambient_git_routing_cannot_redirect_workspace_operations(self):
        with self.assertRaisesRegex(FlurryError, "GIT_DIR"):
            Runner(os.environ | {"GIT_DIR": "/unrelated/repository"}, 10)

    def test_timeout_stops_descendants_before_they_can_write(self):
        with tempfile.TemporaryDirectory() as temporary:
            marker = Path(temporary) / "late-write"
            child = f"import time;from pathlib import Path;time.sleep(0.2);Path({str(marker)!r}).write_text('late')"
            parent = f"import subprocess,sys,time;subprocess.Popen([sys.executable,'-c',{child!r}]);time.sleep(5)"
            with self.assertRaises(FlurryError):
                Runner(os.environ, 0.05).run([sys.executable, "-c", parent], None)
            time.sleep(0.3)
            self.assertFalse(marker.exists(), "Timed-out command left a mutating descendant running")

    def test_timeout_is_not_success(self):
        runner = Runner(os.environ, 0.01)
        with self.assertRaisesRegex(FlurryError, "Cannot execute"):
            runner.run([sys.executable, "-c", "import time;time.sleep(5)"], None)
