import os
import re
import sys
import tempfile
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
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

    def test_command_trace_preserves_results_and_redacts_credentials(self):
        lines = []
        runner = Runner(os.environ, 10, trace=lines.append)
        url = "HtTpS://user:token@forge.example/name"
        args = [sys.executable, "-c", "import sys;print(sys.argv[1]);sys.exit(3)", url, "space and\nnewline\x1b"]
        result = runner.call(args, Path.cwd(), None, {"PRIVATE": "not logged"}, False)
        self.assertEqual((result.returncode, result.stdout), (3, f"{url}\n".encode()))
        self.assertEqual(len(lines), 2)
        self.assertIn("[cmd 1] start: cd ", lines[0])
        self.assertIn("HtTpS://[redacted]@forge.example/name", lines[0])
        self.assertIn("space and\\nnewline\\x1b", lines[0])
        for private in ("user:token", "not logged", "\n", "\x1b"):
            self.assertNotIn(private, lines[0])
        self.assertRegex(lines[1], r"^\[cmd 1\] exit 3 in \d+\.\d{3}s$")

    def test_command_trace_times_checked_errors_launch_failure_and_timeout(self):
        lines = []
        runner = Runner(os.environ, 0.05, trace=lines.append)
        with tempfile.TemporaryDirectory() as temporary:
            for args, match, outcome in (
                (["git", "--not-a-flurry-test-option"], "failed", r"exit [1-9]\d*"),
                ([str(Path(temporary) / "missing-program")], "Cannot execute", "launch failed"),
                ([sys.executable, "-c", "import time;time.sleep(5)"], "timed out", "timed out"),
            ):
                with self.subTest(match=match):
                    with self.assertRaisesRegex(FlurryError, match):
                        runner.run(args, None)
                    self.assertIn("start:", lines[-2])
                    self.assertRegex(lines[-1], rf"{outcome} in \d+\.\d{{3}}s$")

    def test_concurrent_command_trace_pairs_start_and_finish_by_id(self):
        lines = []
        runner = Runner(os.environ, 10, trace=lines.append)
        with ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(lambda _: runner.run(["git", "--version"], None), range(8)))
        starts = [re.match(r"^\[cmd (\d+)\] start:", line)[1] for line in lines if "start:" in line]
        finishes = [re.match(r"^\[cmd (\d+)\] exit 0 in", line)[1] for line in lines if "exit 0 in" in line]
        self.assertEqual(len(set(starts)), 8)
        self.assertCountEqual(starts, finishes)
        for command_id in starts:
            positions = [i for i, line in enumerate(lines) if line.startswith(f"[cmd {command_id}] ")]
            self.assertEqual(len(positions), 2)
            self.assertIn("start:", lines[positions[0]])

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
