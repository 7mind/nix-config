"""Dirty-policy contract: real Git with both dummy and production Nix adapters."""
import contextlib
import io
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

from flurry.cli import main
from flurry.git import Git
from flurry.nix import Nix
from flurry.process import FlurryError, Runner
from flurry.sync import Sync, SyncOptions, plan_sync
from flurry.workspace import load_config


class EmptyInputs:
    def __init__(self, runner):
        self.runner = runner

    def inputs(self, path, *, base=None):
        return ()


class PlanPolicyContract:
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='flurry-plan-policy-')
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.root = self.directory / 'workspace'
        self.root.mkdir()
        self.env = os.environ | {
            'HOME': str(self.directory), 'GIT_CONFIG_GLOBAL': '/dev/null',
            'GIT_CONFIG_NOSYSTEM': '1', 'GIT_OPTIONAL_LOCKS': '0',
            'GIT_AUTHOR_NAME': 'Fixture', 'GIT_AUTHOR_EMAIL': 'fixture@example.invalid',
            'GIT_COMMITTER_NAME': 'Fixture', 'GIT_COMMITTER_EMAIL': 'fixture@example.invalid',
        }
        self.runner = Runner(self.env, 60)
        self.nix = self.nix_adapter(self.runner)
        discovery = patch('flurry.workspace.Nix', self.nix_adapter)
        discovery.start()
        self.addCleanup(discovery.stop)
        self.repo, self.origin = self.add_repo('application')

    def git(self, repo, *args):
        return self.runner.git(repo, *args)

    def add_repo(self, name):
        repo = self.root / name
        origin = self.directory / (name + '.git')
        self.runner.run(['git', 'init', '--quiet', '--bare', '--initial-branch=main', str(origin)], None)
        self.runner.run(['git', 'init', '--quiet', '--initial-branch=main', str(repo)], None)
        (repo / 'flake.nix').write_text('{ outputs = { self }: {}; }\n')
        (repo / 'flake.lock').write_text('{"nodes":{"root":{}},"root":"root","version":7}\n')
        (repo / 'edit.txt').write_text('original\n')
        self.git(repo, 'add', '.')
        self.git(repo, 'commit', '-m', 'initial')
        self.git(repo, 'remote', 'add', 'origin', origin.as_uri())
        self.git(repo, 'push', '--set-upstream', 'origin', 'main')
        return repo, origin

    def options(self, mode, scope):
        return SyncOptions(mode, scope, 'Explicit work' if mode == 'commit' else None, 'eval', ())

    def plan(self, options):
        return plan_sync(load_config(self.root, options.excludes), self.runner, self.nix, options)

    def snapshot(self):
        return (self.git(self.repo, 'rev-parse', 'HEAD'),
                self.git(self.repo, 'ls-files', '--stage', '-z'),
                (self.repo / '.git' / 'index').read_bytes(),
                self.git(self.repo, 'diff', '--binary'),
                self.git(self.repo, 'ls-files', '--others', '--exclude-standard', '-z'),
                self.git(self.origin, 'rev-parse', 'refs/heads/main'))

    def expect_blocked(self, options, reason):
        before = self.snapshot()
        with self.assertRaisesRegex(FlurryError, reason) as planned:
            self.plan(options)
        self.assertFalse((self.root / '.flurry').exists(), 'Plan created execution state')
        service = Sync(self.runner, self.nix, Git(self.runner), lambda message: None)
        with self.assertRaisesRegex(FlurryError, reason) as executed:
            service.run(load_config(self.root, options.excludes), options, None)
        self.assertEqual(str(planned.exception), str(executed.exception))
        self.assertFalse((self.root / '.flurry' / 'runs').exists(), 'A local blocker started a run')
        self.assertEqual(before, self.snapshot())

    def test_preserve_rejects_unstaged_flake_declaration(self):
        declaration = self.repo / 'flake.nix'
        declaration.write_text(declaration.read_text() + '# local work\n')
        self.expect_blocked(self.options('preserve', None), 'pre-existing flake')

    def test_preserve_rejects_staged_lock(self):
        lock = self.repo / 'flake.lock'
        lock.write_text(lock.read_text() + '\n')
        self.git(self.repo, 'add', 'flake.lock')
        self.expect_blocked(self.options('preserve', None), 'pre-existing flake')

    def test_preserve_rejects_canceled_staged_and_unstaged_edits(self):
        lock = self.repo / 'flake.lock'
        original = lock.read_bytes()
        lock.write_bytes(original + b'\n')
        self.git(self.repo, 'add', 'flake.lock')
        lock.write_bytes(original)
        self.assertEqual(self.git(self.repo, 'diff', 'HEAD', '--', 'flake.lock'), b'')
        self.expect_blocked(self.options('preserve', None), 'pre-existing flake')

    def test_preserve_rejects_visible_untracked_lock(self):
        self.git(self.repo, 'rm', 'flake.lock')
        self.git(self.repo, 'commit', '-m', 'defer lock')
        (self.repo / 'flake.lock').write_text('untracked local lock\n')
        self.expect_blocked(self.options('preserve', None), 'pre-existing flake')

    def test_preserve_rejects_deleted_or_renamed_lock(self):
        self.git(self.repo, 'mv', 'flake.lock', 'saved.lock')
        self.expect_blocked(self.options('preserve', None), 'pre-existing flake')

    def test_reject_mode_refuses_unrelated_dirty_work(self):
        (self.repo / 'edit.txt').write_text('local work\n')
        self.expect_blocked(self.options('reject', None), 'Dirty source rejected')

    def test_reject_mode_refuses_visible_untracked_work(self):
        (self.repo / 'untracked').write_text('local work\n')
        self.expect_blocked(self.options('reject', None), 'Dirty source rejected')

    def test_staged_commit_refuses_remaining_unstaged_flake_edit(self):
        lock = self.repo / 'flake.lock'
        lock.write_text(lock.read_text() + '\n')
        self.expect_blocked(self.options('commit', 'staged'), 'staged.*pre-existing flake')

    def test_staged_commit_refuses_untracked_lock(self):
        self.git(self.repo, 'rm', 'flake.lock')
        self.git(self.repo, 'commit', '-m', 'defer lock')
        (self.repo / 'flake.lock').write_text('local lock\n')
        self.expect_blocked(self.options('commit', 'staged'), 'staged.*pre-existing flake')

    def test_clean_and_unrelated_preserved_work_remain_plannable(self):
        self.assertEqual(len(self.plan(self.options('reject', None)).targets), 1)
        (self.repo / 'edit.txt').write_text('local work\n')
        (self.repo / 'untracked').write_text('local work\n')
        self.assertEqual(len(self.plan(self.options('preserve', None)).targets), 1)

    def test_staged_flake_edit_can_be_committed_explicitly(self):
        lock = self.repo / 'flake.lock'
        lock.write_text(lock.read_text() + '\n')
        self.git(self.repo, 'add', 'flake.lock')
        self.assertEqual(len(self.plan(self.options('commit', 'staged')).targets), 1)

    def test_commit_all_can_include_unstaged_flake_edits(self):
        lock = self.repo / 'flake.lock'
        lock.write_text(lock.read_text() + '\n')
        self.assertEqual(len(self.plan(self.options('commit', 'all')).targets), 1)

    def test_excluded_repository_dirt_is_not_validated(self):
        self.add_repo('selected')
        lock = self.repo / 'flake.lock'
        lock.write_text(lock.read_text() + '\n')
        options = SyncOptions('preserve', None, None, 'eval', ('application',))
        self.assertEqual([target.repository.name for target in self.plan(options).targets], ['selected'])

    def test_nested_flake_files_do_not_overlap_root_lock_generation(self):
        nested = self.repo / 'nested'
        nested.mkdir()
        lock = nested / 'flake.lock'
        lock.write_text('original\n')
        self.git(self.repo, 'add', 'nested/flake.lock')
        self.git(self.repo, 'commit', '-m', 'nested fixture')
        lock.write_text('local nested work\n')
        self.assertEqual(len(self.plan(self.options('preserve', None)).targets), 1)

    def test_cli_plan_and_dry_run_both_refuse_the_local_blocker(self):
        declaration = self.repo / 'flake.nix'
        declaration.write_text(declaration.read_text() + '# local work\n')
        for command in (['plan'], ['sync', '--dry-run']):
            with self.subTest(command=command):
                output, errors = io.StringIO(), io.StringIO()
                with patch.dict(os.environ, self.env), patch('flurry.cli.Nix', self.nix_adapter), \
                        contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                    result = main(command + ['--preserve', '--json', '--root', str(self.root)])
                self.assertEqual(result, 1)
                self.assertEqual(output.getvalue(), '')
                self.assertIn('pre-existing flake', errors.getvalue())
                self.assertFalse((self.root / '.flurry').exists())


class LocalPlanPolicyTests(PlanPolicyContract, unittest.TestCase):
    def nix_adapter(self, runner):
        return EmptyInputs(runner)


@unittest.skipUnless(shutil.which('nix') and os.environ.get('FLURRY_REAL_NIX') != '0',
                     'real-Nix leg explicitly disabled or Nix unavailable')
class RealNixPlanPolicyTests(PlanPolicyContract, unittest.TestCase):
    def nix_adapter(self, runner):
        return Nix(runner)
