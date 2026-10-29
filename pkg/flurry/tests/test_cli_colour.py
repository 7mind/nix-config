import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from flurry.cli import main
from flurry.sync import SyncPlan, Target
from flurry.workspace import RepoSettings, Repository, WorkspaceGraph


class TerminalBuffer(io.StringIO):
    def isatty(self):
        return True


class EmptyInputs:
    def __init__(self, runner):
        self.runner = runner

    def inputs(self, path):
        return ()


class CompletedRun:
    def __init__(self, root):
        self.path = root / '.flurry' / 'runs' / 'fixture'
        self.document = {'published': ['application']}


class ReportSync:
    def __init__(self, runner, nix, git, report):
        self.report = report

    def run(self, config, options, resume):
        self.report('Rehearsing application')
        return CompletedRun(config.root)

    def resume(self, config, run_id):
        self.report('Resuming fixture')
        return CompletedRun(config.root)


class PullReport:
    complete = True

    def to_dict(self):
        return {'complete': True, 'entries': [], 'issues': []}


class ReportPull:
    def __init__(self, runner, nix, permissions):
        self.runner = runner

    def plan(self, reference, root, excludes, mappings):
        return PullReport()

    def apply(self, plan):
        return ()


class CliColourTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='flurry-colour-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo_path = self.root / 'application'
        self.repo_path.mkdir()
        self.environment = os.environ | {
            'HOME': str(self.root), 'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_CONFIG_NOSYSTEM': '1',
            'GIT_AUTHOR_NAME': 'Test', 'GIT_AUTHOR_EMAIL': 'test@example.org',
            'GIT_COMMITTER_NAME': 'Test', 'GIT_COMMITTER_EMAIL': 'test@example.org',
            'TERM': 'xterm-256color', 'NO_COLOR': '',
        }
        self.git('init', '--quiet', '--initial-branch=main')
        (self.repo_path / 'tracked').write_text('original\n')
        self.git('add', '.')
        self.git('commit', '--quiet', '-m', 'fixture')
        (self.repo_path / 'tracked').write_text('dirty\n')
        self.repository = Repository(
            'application', self.repo_path, self.repo_path / '.git', 'main',
            self.git('rev-parse', 'HEAD').strip(), 'https://github.com/example/application',
            'origin/main', False, RepoSettings('application', self.repo_path),
        )

    def git(self, *arguments):
        return subprocess.check_output(
            ['git', '-C', str(self.repo_path), '-c', 'core.hooksPath=/dev/null', *arguments],
            env=self.environment, stderr=subprocess.PIPE, text=True,
        )

    def plan(self, config, runner, nix, options):
        target = Target(self.repository, 'origin', 'refs/heads/main', 'origin', 'refs/heads/main',
                        'https://github.com/example/application')
        graph = WorkspaceGraph((self.repository,), ())
        return SyncPlan(graph, (target,), options, (self.repository,))

    def invoke(self, arguments, terminal, machine):
        output = TerminalBuffer() if terminal else io.StringIO()
        errors = TerminalBuffer() if terminal else io.StringIO()
        arguments = list(arguments) + ['--root', str(self.root)]
        if machine:
            arguments.append('--json')
        with patch.dict(os.environ, self.environment), contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors), \
                patch('flurry.cli.discover', lambda config, runner: (self.repository,)), \
                patch('flurry.cli.Nix', EmptyInputs), patch('flurry.cli.plan_sync', self.plan), \
                patch('flurry.cli.Sync', ReportSync), patch('flurry.cli.Pull', ReportPull):
            result = main(arguments)
        return result, output.getvalue(), errors.getvalue()

    def test_plan_is_coloured_by_default_on_terminal(self):
        result, output, errors = self.invoke(['plan'], True, False)
        self.assertEqual(result, 0, errors)
        self.assertIn('\x1b[', output)
        self.assertIn('application', output)
        self.assertIn('Offline plan', output)

    def test_all_human_command_results_are_coloured_on_terminal(self):
        commands = (['status'], ['graph'], ['plan'], ['sync', '--dry-run'], ['sync'],
                    ['resume', 'fixture'], ['pull', 'github:example/application', '--dry-run'],
                    ['pull', 'github:example/application'], ['init'])
        for command in commands:
            with self.subTest(command=command):
                result, output, errors = self.invoke(command, True, False)
                self.assertEqual(result, 0, errors)
                self.assertIn('\x1b[', output)

    def test_piped_output_is_plain_by_default(self):
        for command in (['status'], ['graph'], ['plan'], ['sync'], ['resume', 'fixture'], ['pull', 'example']):
            with self.subTest(command=command):
                result, output, errors = self.invoke(command, False, False)
                self.assertEqual(result, 0, errors)
                self.assertNotIn('\x1b[', output + errors)

    def test_explicit_always_and_never_before_and_after_command(self):
        for arguments, terminal, coloured in ((['--color', 'always', 'plan'], False, True),
                                             (['plan', '--color=always'], False, True),
                                             (['--color=never', 'plan'], True, False),
                                             (['plan', '--color', 'never'], True, False)):
            with self.subTest(arguments=arguments):
                result, output, errors = self.invoke(arguments, terminal, False)
                self.assertEqual(result, 0, errors)
                self.assertEqual('\x1b[' in output, coloured)

    def test_json_is_unchanged_and_plain_even_with_forced_colour(self):
        for command in (['status'], ['graph'], ['plan'], ['sync'], ['resume', 'fixture'],
                        ['pull', 'github:example/application'], ['init']):
            with self.subTest(command=command):
                result, output, errors = self.invoke(command + ['--color=always'], True, True)
                self.assertEqual(result, 0, errors)
                json.loads(output)
                self.assertNotIn('\x1b[', output + errors)

    def test_errors_and_progress_are_coloured_on_terminal(self):
        result, output, errors = self.invoke(['sync'], True, False)
        self.assertEqual(result, 0, errors)
        self.assertIn('\x1b[', errors)
        result, output, errors = self.invoke(['status', '--timeout=0'], True, False)
        self.assertEqual(result, 1)
        self.assertEqual(output, '')
        self.assertIn('\x1b[31m', errors)

    def test_actual_terminal_enables_auto_colour(self):
        import pty
        try:
            master, slave = pty.openpty()
        except OSError as error:
            self.skipTest(f'PTY unavailable: {error}')
        with tempfile.TemporaryDirectory() as empty:
            try:
                result = subprocess.run(
                    [sys.executable, '-m', 'flurry', 'status', '--root', empty],
                    stdout=slave, stderr=subprocess.PIPE, env=self.environment, timeout=15,
                )
            finally:
                os.close(slave)
            rendered = bytearray()
            try:
                while True:
                    try:
                        chunk = os.read(master, 4096)
                    except OSError as error:
                        import errno
                        if error.errno != errno.EIO:
                            raise
                        break
                    if not chunk:
                        break
                    rendered.extend(chunk)
            finally:
                os.close(master)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b'\x1b[', rendered)
