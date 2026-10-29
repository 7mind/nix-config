"""Behavioral/Effectual-GoodCommunication: disposable real Git and local remotes."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from flurry.git import Git
from flurry.process import FlurryError, Runner


class GitTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='flurry-git-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = os.environ | {
            'HOME': str(self.root), 'GIT_CONFIG_GLOBAL': '/dev/null',
            'GIT_CONFIG_NOSYSTEM': '1', 'GIT_ALLOW_PROTOCOL': 'file',
            'GIT_AUTHOR_NAME': 'Fixture', 'GIT_AUTHOR_EMAIL': 'fixture@example.invalid',
            'GIT_COMMITTER_NAME': 'Fixture', 'GIT_COMMITTER_EMAIL': 'fixture@example.invalid',
            'GIT_EDITOR': 'true',
        }
        self.runner = Runner(self.env, 20)
        self.adapter = Git(self.runner)
        self.origin = self.root / 'origin.git'
        self.repo = self.root / 'repo'
        self.seed = self.root / 'seed'
        self.git(self.root, 'init', '--bare', '--initial-branch=main', str(self.origin))
        self.git(self.root, 'init', '--initial-branch=main', str(self.seed))
        for name in ['mixed', 'other', 'flake.nix', 'flake.lock']:
            (self.seed / name).write_text('base\n')
        self.git(self.seed, 'add', '.')
        self.git(self.seed, 'commit', '-m', 'initial')
        self.git(self.seed, 'remote', 'add', 'origin', str(self.origin))
        self.git(self.seed, 'push', '-u', 'origin', 'main')
        self.git(self.root, 'clone', str(self.origin), str(self.repo))

    def git(self, repo, *args):
        return self.runner.git_text(repo, *args)

    def prepare(self, mode='preserve', scope=None):
        return self.adapter.prepare(self.repo, self.root / 'trial', 'main', mode,
                                    'User work' if mode == 'commit' else None, scope)

    def dirty(self):
        (self.repo / 'mixed').write_text('base\nstaged\n')
        self.git(self.repo, 'add', 'mixed')
        (self.repo / 'mixed').write_text('base\nstaged\nunstaged\n')
        (self.repo / 'new file').write_bytes(b'new\x00\xff')

    def snapshot(self):
        return (self.git(self.repo, 'rev-parse', 'HEAD'),
                self.runner.git(self.repo, 'diff', '--cached', '--binary'),
                self.runner.git(self.repo, 'diff', '--binary'),
                self.git(self.repo, 'stash', 'list', '--format=%H'),
                self.runner.git(self.repo, 'ls-files', '--others', '--exclude-standard', '-z'))

    def advance(self, name='upstream'):
        (self.seed / name).write_text('upstream\n')
        self.git(self.seed, 'add', name)
        self.git(self.seed, 'commit', '-m', 'upstream')
        self.git(self.seed, 'push', 'origin', 'main')

    def test_prepare_promote_preserves_split_untracked_stash_and_lock_commit(self):
        (self.repo / 'other').write_text('old stash\n')
        self.git(self.repo, 'stash', 'push', '-m', 'old')
        self.dirty()
        before = self.snapshot()
        self.advance()
        prepared = self.prepare()
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.git(prepared.trial, 'status', '--porcelain'), '')
        (prepared.trial / 'flake.lock').write_text('new lock\n')
        self.adapter.commit_lock(prepared)
        self.adapter.rehearse_restore(prepared)
        record = self.adapter.promote(prepared, 'fixture')
        after = self.snapshot()
        self.assertEqual(after[1:], before[1:])
        self.assertEqual((self.repo / 'new file').read_bytes(), b'new\x00\xff')
        self.assertEqual(self.git(self.repo, 'show', ':mixed'), 'base\nstaged')
        self.assertEqual(self.git(self.repo, 'show', 'HEAD:flake.lock'), 'new lock')
        self.adapter.recover(record)
        self.assertEqual(self.snapshot(), before)

    def test_staged_commit_excludes_unstaged_and_untracked(self):
        self.dirty()
        before = self.snapshot()
        prepared = self.prepare('commit', 'staged')
        self.assertEqual(self.git(prepared.trial, 'show', 'HEAD:mixed'), 'base\nstaged')
        record = self.adapter.promote(prepared, 'staged')
        self.assertEqual(self.git(self.repo, 'diff', '--cached'), '')
        self.assertIn('unstaged', self.git(self.repo, 'diff'))
        self.assertTrue((self.repo / 'new file').exists())
        self.adapter.recover(record)
        self.assertEqual(self.snapshot(), before)

    def test_all_commit_includes_visible_untracked(self):
        self.dirty()
        before = self.snapshot()
        prepared = self.prepare('commit', 'all')
        record = self.adapter.promote(prepared, 'all')
        self.assertEqual(self.git(self.repo, 'status', '--porcelain'), '')
        self.assertEqual(self.git(self.repo, 'log', '-1', '--format=%s'), 'User work')
        self.adapter.recover(record)
        self.assertEqual(self.snapshot(), before)

    def test_staged_commit_skips_empty_index_preserving_remainder(self):
        (self.repo / 'mixed').write_text('unstaged only\n')
        (self.repo / 'untracked').write_text('untracked only\n')
        before = self.snapshot()
        prepared = self.prepare('commit', 'staged')
        self.assertEqual(prepared.head, before[0])
        self.adapter.promote(prepared, 'empty-staged')
        self.assertEqual(self.snapshot(), before)

    def test_serialized_config_does_not_contain_credentials(self):
        self.git(self.repo, 'config', 'http.extraHeader', 'Authorization: secret-value')
        prepared = self.prepare()
        serialized = prepared.original.to_dict()
        self.assertNotIn('secret-value'.encode().hex(), str(serialized))
        self.assertEqual(len(serialized['config']), 64)

    def test_source_changed_refuses_promotion(self):
        prepared = self.prepare()
        (self.repo / 'concurrent').write_text('keep')
        with self.assertRaisesRegex(FlurryError, 'changed during rehearsal'):
            self.adapter.promote(prepared, 'changed')
        self.assertEqual((self.repo / 'concurrent').read_text(), 'keep')

    def test_restore_conflict_is_rehearsed_without_source_changes(self):
        (self.repo / 'mixed').write_text('dirty conflict\n')
        before = self.snapshot()
        self.advance('mixed')
        with self.assertRaisesRegex(FlurryError, 'restore'):
            self.prepare()
        self.assertEqual(self.snapshot(), before)

    def test_special_flags_and_intent_refused(self):
        for flag in ['--assume-unchanged', '--skip-worktree']:
            self.git(self.repo, 'update-index', flag, 'mixed')
            with self.assertRaisesRegex(FlurryError, 'index flags'):
                self.prepare()
            self.git(self.repo, 'update-index', flag.replace('--', '--no-', 1), 'mixed')
        (self.repo / 'intent').write_text('intent')
        self.git(self.repo, 'add', '-N', 'intent')
        with self.assertRaisesRegex(FlurryError, 'Intent-to-add'):
            self.prepare()

    def test_ignored_incoming_collision_refused(self):
        (self.repo / '.git/info/exclude').write_text('upstream\n')
        (self.repo / 'upstream').write_text('ignored valuable')
        before = self.snapshot()
        self.advance()
        with self.assertRaisesRegex(FlurryError, 'ignored'):
            self.prepare()
        self.assertEqual(self.snapshot(), before)
        self.assertEqual((self.repo / 'upstream').read_text(), 'ignored valuable')

    def test_preserved_flake_overlap_refused(self):
        (self.repo / 'flake.lock').write_text('user lock')
        with self.assertRaisesRegex(FlurryError, 'flake'):
            self.prepare()

    def test_requested_commit_hook_not_silently_skipped(self):
        self.dirty()
        hook = self.repo / '.git/hooks/pre-commit'
        hook.write_text('#!/bin/sh\nexit 1\n')
        hook.chmod(0o755)
        with self.assertRaisesRegex(FlurryError, 'hook'):
            self.prepare('commit', 'all')

    def test_push_normal_and_remote_verified(self):
        self.advance()
        prepared = self.prepare()
        self.adapter.promote(prepared, 'push')
        self.adapter.push(self.repo, 'origin', 'refs/heads/main', prepared.head)
        self.assertEqual(self.git(self.origin, 'rev-parse', 'main'), prepared.head)

    def test_untracked_binary_symlink_mode_and_literal_paths_roundtrip(self):
        self.dirty()
        executable = self.repo / ':(glob)literal\nname'
        executable.write_bytes(b'#!/bin/sh\nexit 0\n')
        executable.chmod(0o755)
        link = self.repo / 'symlink'
        link.symlink_to('outside-target')
        prepared = self.prepare()
        self.adapter.promote(prepared, 'literal')
        self.assertEqual(executable.read_bytes(), b'#!/bin/sh\nexit 0\n')
        self.assertTrue(executable.stat().st_mode & 0o111)
        self.assertEqual(os.readlink(link), 'outside-target')

    def test_ignored_directory_obstructing_old_path_refused(self):
        path = self.repo / 'mixed'
        path.unlink()
        path.mkdir()
        (path / 'valuable').write_bytes(b'valuable\x00')
        (self.repo / '.git/info/exclude').write_text('mixed/\n')
        with self.assertRaisesRegex(FlurryError, 'obstruct'):
            self.prepare()
        self.assertEqual((path / 'valuable').read_bytes(), b'valuable\x00')

    def test_lossy_config_refused(self):
        self.git(self.repo, 'config', 'core.autocrlf', 'input')
        (self.repo / 'crlf').write_bytes(b'line\r\n')
        with self.assertRaisesRegex(FlurryError, 'lossy'):
            self.prepare()
        self.assertEqual((self.repo / 'crlf').read_bytes(), b'line\r\n')

    def test_local_identity_retained_without_identity_environment(self):
        for kind in ('AUTHOR', 'COMMITTER'):
            for key in ('NAME', 'EMAIL'):
                self.runner.environment.pop(f'GIT_{kind}_{key}')
        self.git(self.repo, 'config', 'user.name', 'Source Identity')
        self.git(self.repo, 'config', 'user.email', 'source@example.invalid')
        self.dirty()
        prepared = self.prepare('commit', 'all')
        self.assertEqual(self.git(prepared.trial, 'log', '-1', '--format=%cn <%ce>'),
                         'Source Identity <source@example.invalid>')

    def test_unavailable_required_signer_fails_before_source_changes(self):
        (self.repo / 'local').write_text('local')
        self.git(self.repo, 'add', 'local')
        self.git(self.repo, 'commit', '-m', 'local')
        self.git(self.repo, 'config', 'commit.gpgSign', 'true')
        self.git(self.repo, 'config', 'gpg.format', 'ssh')
        self.git(self.repo, 'config', 'user.signingKey', 'unavailable-key')
        self.git(self.repo, 'config', 'gpg.ssh.program', str(self.root / 'unavailable-signer'))
        before = self.snapshot()
        self.advance()
        with self.assertRaisesRegex(FlurryError, 'unavailable-signer'):
            self.prepare()
        self.assertEqual(self.snapshot(), before)

    def test_ambient_git_routing_refused(self):
        with self.assertRaisesRegex(FlurryError, 'GIT_WORK_TREE'):
            runner = Runner(self.env | {'GIT_WORK_TREE': str(self.seed)}, 20)
            Git(runner)

    def test_recovery_refuses_new_ignored_original_path_collision(self):
        self.git(self.seed, 'rm', 'other')
        self.git(self.seed, 'commit', '-m', 'remove other')
        self.git(self.seed, 'push', 'origin', 'main')
        (self.repo / '.git/info/exclude').write_text('other\n')
        record = self.adapter.promote(self.prepare(), 'ignored-recovery')
        (self.repo / 'other').write_text('valuable ignored data')
        with self.assertRaisesRegex(FlurryError, 'ignored'):
            self.adapter.recover(record)
        self.assertEqual((self.repo / 'other').read_text(), 'valuable ignored data')

    def test_commit_promotion_detects_late_captured_edit(self):
        self.dirty()
        prepared = self.prepare('commit', 'all')
        original_call = self.runner.call
        mutated = False

        def call(args, cwd, input_data, extra_env, check):
            nonlocal mutated
            if 'stash' in args and 'push' in args and str(self.repo) in args and not mutated:
                mutated = True
                (self.repo / 'late-edit').write_text('late valuable edit')
            return original_call(args, cwd, input_data, extra_env, check)

        self.runner.call = call
        with self.assertRaisesRegex(FlurryError, 'changed|captured') as raised:
            self.adapter.promote(prepared, 'late-edit')
        record = raised.exception.recovery
        self.assertEqual(self.git(self.repo, 'show', f'{record.stash_ref}^3:late-edit'),
                         'late valuable edit')

    def assert_late_ref_mutation_refused(self, mutation):
        prepared = self.prepare()
        original_call = self.runner.call
        mutated = False

        def call(args, cwd, input_data, extra_env, check):
            nonlocal mutated
            if 'stash' in args and 'push' in args and str(self.repo) in args and not mutated:
                mutated = True
                if mutation == 'empty-commit':
                    self.git(self.repo, 'commit', '--allow-empty', '--only', '-m', 'concurrent empty')
                else:
                    self.git(self.repo, 'branch', 'unexpected')
                    self.git(self.repo, 'symbolic-ref', 'HEAD', 'refs/heads/unexpected')
            return original_call(args, cwd, input_data, extra_env, check)

        self.runner.call = call
        with self.assertRaisesRegex(FlurryError, 'changed|parent|branch'):
            self.adapter.promote(prepared, mutation)

    def test_actual_stash_parent_is_validated(self):
        self.assert_late_ref_mutation_refused('empty-commit')

    def test_actual_stash_branch_is_validated(self):
        self.assert_late_ref_mutation_refused('switch-branch')

    def test_promotion_does_not_claim_late_edits_as_owned_output(self):
        self.dirty()
        prepared = self.prepare('commit', 'all')
        original_drop = self.adapter._drop_stash

        def drop(repo, oid):
            original_drop(repo, oid)
            (self.repo / 'mixed').write_text('late valuable content')

        self.adapter._drop_stash = drop
        with self.assertRaisesRegex(FlurryError, 'postcondition|changed') as raised:
            self.adapter.promote(prepared, 'late-output')
        self.assertIsNone(raised.exception.recovery.promoted)
        self.assertEqual((self.repo / 'mixed').read_text(), 'late valuable content')

    def test_recovery_refuses_new_git_operation(self):
        record = self.adapter.promote(self.prepare(), 'merge')
        operation = self.repo / '.git/MERGE_HEAD'
        operation.write_text(record.prepared.head + '\n')
        with self.assertRaisesRegex(FlurryError, 'operation'):
            self.adapter.recover(record)
        self.assertTrue(operation.exists())

    def test_recovery_refuses_concurrent_edits(self):
        record = self.adapter.promote(self.prepare(), 'recover')
        (self.repo / 'mixed').write_text('concurrent valuable')
        with self.assertRaisesRegex(FlurryError, 'changed|ambiguous'):
            self.adapter.recover(record)
        self.assertEqual((self.repo / 'mixed').read_text(), 'concurrent valuable')


if __name__ == '__main__':
    unittest.main()
