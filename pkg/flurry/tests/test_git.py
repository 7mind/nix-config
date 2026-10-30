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

    def configure_filter(self, name):
        marker = self.root / 'filter-executed'
        program = self.root / 'filter-command'
        program.write_text(f'#!/bin/sh\nprintf invoked > "{marker}"\nexit 19\n')
        program.chmod(0o755)
        configuration = self.root / 'global.gitconfig'
        for setting in ('clean', 'smudge', 'process'):
            self.git(self.root, 'config', '--file', str(configuration), f'filter.{name}.{setting}', str(program))
        self.git(self.root, 'config', '--file', str(configuration), f'filter.{name}.required', 'true')
        self.runner.environment['GIT_CONFIG_GLOBAL'] = str(configuration)
        return marker

    def test_unused_global_filter_registration_preserves_dirty_state(self):
        marker = self.configure_filter('lfs')
        self.dirty()
        before = self.snapshot()
        self.advance()
        prepared = self.prepare()
        record = self.adapter.promote(prepared, 'unused-filter')
        self.assertEqual(self.snapshot()[1:], before[1:])
        self.adapter.recover(record)
        self.assertEqual(self.snapshot(), before)
        self.assertFalse(marker.exists(), 'An unused filter command was executed')

    def assert_filter_refused_without_source_changes(self, marker, reason):
        before = (self.git(self.repo, 'rev-parse', 'HEAD'), self.git(self.repo, 'write-tree'),
                  (self.repo / 'mixed').read_bytes(), self.git(self.repo, 'stash', 'list', '--format=%H'))
        self.assertFalse(marker.exists(), 'Fixture setup executed a filter')
        with tempfile.TemporaryDirectory(dir=self.root, prefix='refusal-') as temporary:
            with self.assertRaisesRegex(FlurryError, reason):
                self.adapter.prepare(self.repo, Path(temporary) / 'trial', 'main', 'preserve', None, None)
        after = (self.git(self.repo, 'rev-parse', 'HEAD'), self.git(self.repo, 'write-tree'),
                 (self.repo / 'mixed').read_bytes(), self.git(self.repo, 'stash', 'list', '--format=%H'))
        self.assertEqual(before, after)
        self.assertFalse(marker.exists(), 'The unsupported filter was executed before refusal')

    def test_effective_filter_is_rejected_in_worktree_index_and_head_views(self):
        marker = self.configure_filter('lfs')
        attributes = self.repo / '.gitattributes'
        attributes.write_text('mixed filter=lfs\n')
        self.assert_filter_refused_without_source_changes(marker, 'mixed.*working tree')
        self.adapter._git(self.repo, 'add', '.gitattributes', env={'GIT_CONFIG_GLOBAL': '/dev/null'})
        attributes.write_text('')
        self.assert_filter_refused_without_source_changes(marker, 'mixed.*index')
        self.adapter._git(self.repo, 'commit', '-m', 'attributes', env={'GIT_CONFIG_GLOBAL': '/dev/null'})
        self.adapter._git(self.repo, 'add', '.gitattributes', env={'GIT_CONFIG_GLOBAL': '/dev/null'})
        self.assert_filter_refused_without_source_changes(marker, 'mixed.*HEAD')

    def test_visible_untracked_filter_is_rejected_before_snapshot_add(self):
        marker = self.configure_filter('lfs')
        (self.repo / '.gitattributes').write_text('*.bin filter=lfs\n')
        (self.repo / 'new.bin').write_bytes(b'valuable\x00\xff')
        self.assert_filter_refused_without_source_changes(marker, 'new.bin')
        self.assertEqual((self.repo / 'new.bin').read_bytes(), b'valuable\x00\xff')

    def test_filter_on_generated_lock_or_sentinel_is_rejected(self):
        marker = self.configure_filter('lfs')
        self.git(self.repo, 'rm', 'flake.lock')
        self.git(self.repo, 'commit', '-m', 'remove lock')
        attributes = self.repo / '.gitattributes'
        attributes.write_text('flake.lock filter=lfs\n')
        self.assert_filter_refused_without_source_changes(marker, 'flake.lock')
        attributes.write_text('.flurry-* filter=lfs\n')
        self.assert_filter_refused_without_source_changes(marker, r'\.flurry-')
        self.assertEqual(list(self.repo.glob('.flurry-*')), [])

    def filtered_upstream(self, attributes):
        (self.seed / 'future.dat').write_bytes(b'new upstream data\n')
        if attributes:
            (self.seed / '.gitattributes').write_text(attributes)
        for args in (('add', '.'), ('commit', '-m', 'incoming files')):
            self.adapter._git(self.seed, *args, env={'GIT_CONFIG_GLOBAL': '/dev/null'})
        self.git(self.seed, 'push', 'origin', 'main')

    def test_incoming_filter_is_rejected_before_checkout(self):
        marker = self.configure_filter('lfs')
        self.filtered_upstream('future.dat filter=lfs\n')
        self.assert_filter_refused_without_source_changes(marker, 'future.dat')
        self.assertFalse((self.repo / 'future.dat').exists())

    def test_global_and_dirty_attributes_are_checked_for_incoming_paths(self):
        marker = self.configure_filter('lfs')
        attributes = self.root / 'global.attributes'
        attributes.write_text('future.dat filter=lfs\n')
        self.git(self.root, 'config', '--file', self.runner.environment['GIT_CONFIG_GLOBAL'], 'core.attributesFile', str(attributes))
        self.filtered_upstream('')
        self.assert_filter_refused_without_source_changes(marker, 'future.dat')
        attributes.write_text('')
        (self.repo / '.gitattributes').write_text('future.dat filter=lfs\n')
        self.assert_filter_refused_without_source_changes(marker, 'future.dat')

    def test_preserved_and_incoming_attribute_merges_are_refused(self):
        marker = self.configure_filter('lfs')
        nested = self.repo / 'nested'
        nested.mkdir()
        (nested / '.gitattributes').write_text('future.dat media\n')
        self.filtered_upstream('[attr]media filter=lfs\n')
        self.assert_filter_refused_without_source_changes(marker, 'Cannot safely merge preserved .gitattributes')
        self.assertEqual((nested / '.gitattributes').read_text(), 'future.dat media\n')

    def test_attribute_merge_guard_includes_canceled_staged_edits(self):
        marker = self.configure_filter('lfs')
        nested = self.repo / 'nested'
        nested.mkdir()
        attributes = nested / '.gitattributes'
        attributes.write_text('')
        self.git(self.repo, 'add', 'nested/.gitattributes')
        self.git(self.repo, 'commit', '-m', 'nested attributes')
        attributes.write_text('future.dat media\n')
        self.git(self.repo, 'add', 'nested/.gitattributes')
        attributes.write_text('')
        incoming = self.seed / 'nested'
        incoming.mkdir()
        (incoming / 'future.dat').write_text('incoming data\n')
        self.filtered_upstream('[attr]media filter=lfs\n')
        self.assert_filter_refused_without_source_changes(marker, 'Cannot safely merge preserved .gitattributes')

    def test_attribute_context_of_untracked_snapshot_is_checked(self):
        marker = self.configure_filter('lfs')
        attributes = self.repo / '.gitattributes'
        attributes.write_text('*.bin -filter\n')
        self.git(self.repo, 'add', '.gitattributes')
        self.git(self.repo, 'commit', '-m', 'disable binary filtering')
        global_attributes = self.root / 'global.attributes'
        global_attributes.write_text('*.bin filter=lfs\n')
        self.git(self.root, 'config', '--file', self.runner.environment['GIT_CONFIG_GLOBAL'], 'core.attributesFile', str(global_attributes))
        attributes.unlink()
        (self.repo / 'new.bin').write_bytes(b'valuable\x00\xff')
        self.assert_filter_refused_without_source_changes(marker, 'new.bin.*untracked snapshot')

    def test_attribute_context_of_untracked_checkout_is_checked(self):
        marker = self.configure_filter('lfs')
        attributes = self.repo / '.gitattributes'
        attributes.write_text('*.bin -filter\n')
        (self.repo / '.gitignore').write_text('ignored\nnested/.gitattributes\n')
        self.git(self.repo, 'add', '.gitattributes', '.gitignore')
        self.git(self.repo, 'commit', '-m', 'disable binary filtering')
        global_attributes = self.root / 'global.attributes'
        global_attributes.write_text('*.bin filter=lfs\n')
        self.git(self.root, 'config', '--file', self.runner.environment['GIT_CONFIG_GLOBAL'], 'core.attributesFile', str(global_attributes))
        attributes.unlink()
        nested = self.repo / 'nested'
        nested.mkdir()
        (nested / '.gitattributes').write_text('*.bin -filter\n')
        (nested / 'new.bin').write_bytes(b'valuable\x00\xff')
        self.assert_filter_refused_without_source_changes(marker, 'Uncaptured Git attribute file.*nested/.gitattributes')

    def source_only_attribute_fixture(self, existing):
        marker = self.configure_filter('lfs')
        (self.seed / '.gitattributes').write_text('')
        (self.seed / '.gitignore').write_text('ignored\nnested/.gitattributes\n')
        if existing:
            (self.seed / 'nested').mkdir()
            (self.seed / 'nested' / 'file.dat').write_text('original data\n')
        self.git(self.seed, 'add', '.')
        self.git(self.seed, 'commit', '-m', 'attribute fixture')
        self.git(self.seed, 'push', 'origin', 'main')
        self.git(self.repo, 'fetch', 'origin')
        self.git(self.repo, 'merge', '--ff-only', 'origin/main')
        global_attributes = self.root / 'global.attributes'
        global_attributes.write_text('nested/*.dat media\n')
        self.git(self.root, 'config', '--file', self.runner.environment['GIT_CONFIG_GLOBAL'], 'core.attributesFile', str(global_attributes))
        (self.repo / '.gitattributes').write_text('[attr]media filter=lfs\n')
        nested = self.repo / 'nested'
        nested.mkdir(exist_ok=True)
        (nested / '.gitattributes').write_text('*.dat -filter\n')
        return marker

    def test_ignored_source_attributes_cannot_hide_trial_filter_on_existing_file(self):
        marker = self.source_only_attribute_fixture(True)
        self.assert_filter_refused_without_source_changes(marker, 'Uncaptured Git attribute file.*nested/.gitattributes')

    def test_ignored_source_attributes_cannot_hide_trial_filter_on_incoming_file(self):
        marker = self.source_only_attribute_fixture(False)
        (self.seed / 'nested').mkdir()
        (self.seed / 'nested' / 'future.dat').write_text('incoming data\n')
        self.filtered_upstream('')
        self.assert_filter_refused_without_source_changes(marker, 'Uncaptured Git attribute file.*nested/.gitattributes')

    def test_disabled_filter_attributes_remain_allowed_with_unused_driver(self):
        marker = self.configure_filter('lfs')
        (self.repo / '.gitattributes').write_text('* -filter\n')
        prepared = self.prepare()
        self.adapter.promote(prepared, 'disabled-filter')
        self.assertFalse(marker.exists())

    def test_reserved_filter_driver_names_fail_closed(self):
        for name in ('unset', 'unspecified'):
            with self.subTest(name=name):
                marker = self.configure_filter(name)
                (self.repo / '.gitattributes').write_text(f'mixed filter={name}\n')
                self.assert_filter_refused_without_source_changes(marker, 'Ambiguous reserved Git filter name')

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

    def install_commit_hook(self, directory, name, body):
        directory.mkdir(parents=True, exist_ok=True)
        hook = directory / name
        hook.write_text('#!/bin/sh\nset -eu\n' + body + '\n')
        hook.chmod(0o755)
        return hook

    def test_generated_lock_runs_source_hooks_against_candidate_only(self):
        self.dirty()
        before = self.snapshot()
        directory = self.repo / '.git/hooks'
        audit = self.root / 'hook-context'
        self.install_commit_hook(directory, 'check-candidate',
            f'git rev-parse --show-toplevel > "{audit}"\n'
            f'git diff --cached --name-only >> "{audit}"\n'
            f'git show :flake.lock >> "{audit}"\n'
            'test "$(git show :mixed)" = base')
        self.install_commit_hook(directory, 'pre-commit', 'exec "$(dirname "$0")/check-candidate"')
        prepared = self.prepare()
        (prepared.trial / 'flake.lock').write_text('generated\n')
        self.adapter.commit_lock(prepared)
        self.assertEqual(audit.read_text().splitlines(), [str(prepared.trial), 'flake.lock', 'generated'])
        self.assertEqual(self.snapshot(), before)
        self.adapter.promote(prepared, 'hook-preserve')
        self.assertEqual(self.snapshot()[1:], before[1:])
        self.assertEqual((self.repo / 'new file').read_bytes(), b'new\x00\xff')
        self.assertEqual(self.git(self.repo, 'show', 'HEAD:flake.lock'), 'generated')

    def test_relative_hooks_path_uses_source_scripts_and_helpers(self):
        directory = self.repo / 'source hooks'
        (self.repo / '.git/info/exclude').write_text('source hooks/\n')
        self.git(self.repo, 'config', 'core.hooksPath', 'source hooks')
        audit = self.root / 'hook-context'
        self.install_commit_hook(directory, 'helper', f'git rev-parse --show-toplevel > "{audit}"')
        self.install_commit_hook(directory, 'pre-commit', 'exec "$(dirname "$0")/helper"')
        prepared = self.prepare()
        (prepared.trial / 'flake.lock').write_text('generated\n')
        self.adapter.commit_lock(prepared)
        self.assertEqual(audit.read_text().strip(), str(prepared.trial))

    def test_source_conditional_global_hooks_path_is_honored(self):
        directory = self.root / 'global hooks'
        audit = self.root / 'hook-context'
        self.install_commit_hook(directory, 'pre-commit', f'git rev-parse --show-toplevel > "{audit}"')
        included = self.root / 'source-config'
        configuration = self.root / 'global-config'
        self.git(self.root, 'config', '--file', str(included), 'core.hooksPath', str(directory))
        self.git(self.root, 'config', '--file', str(configuration),
                 f'includeIf.gitdir:{self.repo}/.git.path', str(included))
        self.runner.environment['GIT_CONFIG_GLOBAL'] = str(configuration)
        configured = self.runner.text(['git', '-C', str(self.repo), 'config', '--get', 'core.hooksPath'], None)
        self.assertEqual(configured, str(directory))
        prepared = self.prepare()
        (prepared.trial / 'flake.lock').write_text('generated\n')
        self.adapter.commit_lock(prepared)
        self.assertEqual(audit.read_text().strip(), str(prepared.trial))

    def test_linked_worktree_resolves_common_and_per_worktree_hooks(self):
        primary = self.repo
        linked = self.root / 'linked checkout'
        self.git(primary, 'worktree', 'add', '-b', 'linked', str(linked))
        self.repo = linked
        audit = self.root / 'hook-context'
        common_hooks = primary / '.git/hooks'
        self.install_commit_hook(common_hooks, 'pre-commit', f'git rev-parse --show-toplevel > "{audit}"')
        prepared = self.prepare()
        (prepared.trial / 'flake.lock').write_text('generated\n')
        self.adapter.commit_lock(prepared)
        self.assertEqual(audit.read_text().strip(), str(prepared.trial))
        worktree_hooks = self.root / 'worktree hooks'
        self.install_commit_hook(worktree_hooks, 'pre-commit', f'printf worktree > "{audit}"')
        self.git(primary, 'config', 'extensions.worktreeConfig', 'true')
        self.git(linked, 'config', '--worktree', 'core.hooksPath', str(worktree_hooks))
        prepared = self.adapter.prepare(linked, self.root / 'worktree trial', 'main', 'preserve', None, None)
        (prepared.trial / 'flake.lock').write_text('generated\n')
        self.adapter.commit_lock(prepared)
        self.assertEqual(audit.read_text(), 'worktree')

    def test_requested_commits_honor_hooks_and_explicit_scope(self):
        self.dirty()
        before = self.snapshot()
        directory = self.repo / '.git/hooks'
        audit = self.root / 'hook-context'
        self.install_commit_hook(directory, 'pre-commit', f'git diff --cached --name-only > "{audit}"')
        self.install_commit_hook(directory, 'prepare-commit-msg', 'test "$2" = message')
        self.install_commit_hook(directory, 'commit-msg', 'printf "policy-approved message\\n" > "$1"')
        self.install_commit_hook(directory, 'post-commit', 'test "$(git log -1 --format=%s)" = "policy-approved message"')
        for scope, paths in [('staged', {'mixed'}), ('all', {'mixed', 'new file'})]:
            with self.subTest(scope=scope):
                prepared = self.adapter.prepare(self.repo, self.root / scope, 'main', 'commit', 'User work', scope)
                self.assertEqual(set(audit.read_text().splitlines()), paths)
                self.assertEqual(self.git(prepared.trial, 'log', '-1', '--format=%s'), 'policy-approved message')
                self.assertEqual(self.snapshot(), before)

    def test_intentional_commits_allow_staged_deletions_and_renames(self):
        self.git(self.repo, 'rm', 'other')
        self.git(self.repo, 'mv', 'mixed', 'renamed')
        before = self.snapshot()
        for scope in ('staged', 'all'):
            with self.subTest(scope=scope):
                prepared = self.adapter.prepare(self.repo, self.root / scope, 'main', 'commit', 'Remove and rename', scope)
                paths = self.git(prepared.trial, 'ls-tree', '-r', '--name-only', 'HEAD').splitlines()
                self.assertNotIn('other', paths)
                self.assertNotIn('mixed', paths)
                self.assertIn('renamed', paths)
                self.assertEqual(self.snapshot(), before)

    def test_commit_gates_execute_and_veto_without_touching_source(self):
        self.dirty()
        before = self.snapshot()
        directory = self.repo / '.git/hooks'
        audit = self.root / 'hook-context'
        for name in ('pre-commit', 'prepare-commit-msg', 'commit-msg'):
            with self.subTest(hook=name):
                hook = self.install_commit_hook(directory, name,
                    f'git rev-parse --show-toplevel > "{audit}"\nprintf "policy-refused\\n" >&2\nexit 1')
                trial = self.root / name
                with self.assertRaisesRegex(FlurryError, 'policy-refused'):
                    self.adapter.prepare(self.repo, trial, 'main', 'commit', 'User work', 'all')
                self.assertEqual(audit.read_text().strip(), str(trial))
                self.assertEqual(self.snapshot(), before)
                self.assertEqual(self.git(trial, 'rev-parse', 'HEAD'), before[0])
                hook.unlink()

    def test_hook_mutations_cannot_publish_a_different_candidate(self):
        self.dirty()
        before = self.snapshot()
        directory = self.repo / '.git/hooks'
        cases = [
            ('extra-staged', 'pre-commit', 'printf extra > other\ngit add other'),
            ('lock-rewrite', 'pre-commit', 'printf wrong > flake.lock\ngit add flake.lock'),
            ('unstaged', 'pre-commit', 'printf changed > mixed'),
            ('untracked', 'pre-commit', 'printf hidden > unexpected'),
            ('config', 'pre-commit', 'git config hook.changed true'),
            ('branch', 'post-commit', 'git checkout -b unexpected'),
            ('extra-commit', 'post-commit', 'git -c core.hooksPath=/dev/null commit --allow-empty -m extra'),
        ]
        for name, event, body in cases:
            with self.subTest(mutation=name):
                prepared = self.adapter.prepare(self.repo, self.root / name, 'main', 'preserve', None, None)
                hook = self.install_commit_hook(directory, event, body)
                (prepared.trial / 'flake.lock').write_text('generated\n')
                with self.assertRaisesRegex(FlurryError, 'Commit hook.*changed'):
                    self.adapter.commit_lock(prepared)
                self.assertEqual(self.snapshot(), before)
                self.assertEqual(self.git(self.origin, 'rev-parse', 'main'), before[0])
                hook.unlink()

    def test_internal_checkout_hooks_stay_disabled(self):
        marker = self.root / 'internal-hook-ran'
        self.install_commit_hook(self.repo / '.git/hooks', 'post-checkout', f'touch "{marker}"')
        prepared = self.prepare()
        (prepared.trial / 'flake.lock').write_text('generated\n')
        self.adapter.commit_lock(prepared)
        self.adapter.promote(prepared, 'internal-hooks')
        self.assertFalse(marker.exists())

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
