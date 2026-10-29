from __future__ import annotations

import hashlib
import os
from dataclasses import asdict, dataclass
from pathlib import Path
import re
import stat
import tempfile
import uuid

from .process import FlurryError, Runner


@dataclass(frozen=True)
class FileState:
    path: str
    kind: str
    executable: bool
    digest: str


@dataclass(frozen=True)
class Snapshot:
    head: str
    branch: str
    index_tree: str
    worktree_patch: bytes
    untracked_tree: str
    untracked: tuple[str, ...]
    files: tuple[FileState, ...]
    flags: bytes
    stashes: bytes
    config: bytes
    identity: tuple[tuple[str, str], ...]

    def to_dict(self) -> dict:
        result = asdict(self)
        for field in ('worktree_patch', 'flags', 'stashes'):
            result[field] = getattr(self, field).hex()
        result['config'] = hashlib.sha256(self.config).hexdigest()
        return result


@dataclass
class Prepared:
    repo: Path
    trial: Path
    original: Snapshot
    head: str
    baseline: str
    branch: str
    remote: str
    remote_url: str
    remaining_stash: str
    marker: str
    dirty_mode: str
    restored: Snapshot | None = None


@dataclass
class Recovery:
    prepared: Prepared
    stash_ref: str
    prepared_ref: str
    original_stash: str
    promoted: Snapshot | None
    phase: str

    def to_dict(self) -> dict:
        return {
            'repo': str(self.prepared.repo), 'trial': str(self.prepared.trial),
            'original': self.prepared.original.to_dict(),
            'prepared_head': self.prepared.head, 'marker': self.prepared.marker,
            'dirty_mode': self.prepared.dirty_mode,
            'stash_ref': self.stash_ref, 'prepared_ref': self.prepared_ref,
            'original_stash': self.original_stash, 'phase': self.phase,
            'promoted': None if self.promoted is None else self.promoted.to_dict(),
        }


class PromotionError(FlurryError):
    def __init__(self, message: str, recovery: Recovery):
        super().__init__(message)
        self.recovery = recovery


class Git:
    def __init__(self, runner: Runner):
        for variable in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR',
                         'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES',
                         'GIT_CONFIG_COUNT', 'GIT_CONFIG_PARAMETERS', 'GIT_NAMESPACE'):
            if runner.environment.get(variable):
                raise FlurryError(f'Ambient Git routing/configuration is unsupported: {variable}')
        self.runner = runner

    def _git(self, repo: Path, *args: str, input_data: bytes | None = None,
             env: dict[str, str] | None = None, check: bool = True) -> bytes:
        return self.runner.call([
            'git', '-C', str(repo), '-c', 'submodule.recurse=false',
            '-c', 'diff.ignoreSubmodules=all', '-c', 'core.hooksPath=/dev/null',
            *args,
        ], None, input_data, {} if env is None else env, check).stdout

    def _text(self, repo: Path, *args: str, **kwargs) -> str:
        return self._git(repo, *args, **kwargs).decode(errors='surrogateescape').strip()

    def _succeeds(self, repo: Path, *args: str) -> bool:
        result = self.runner.call([
            'git', '-C', str(repo), '-c', 'submodule.recurse=false',
            '-c', 'core.hooksPath=/dev/null', *args,
        ], None, None, {}, False)
        return result.returncode == 0

    @staticmethod
    def _paths(data: bytes) -> tuple[str, ...]:
        return tuple(os.fsdecode(path) for path in data.split(b'\0') if path)

    def _tree_paths(self, repo: Path, tree: str) -> tuple[str, ...]:
        return self._paths(self._git(repo, 'ls-tree', '-r', '--name-only', '-z', tree))

    def _files(self, repo: Path, paths: tuple[str, ...]) -> tuple[FileState, ...]:
        result = []
        for name in sorted(set(paths)):
            path = repo / name
            if path.is_symlink():
                result.append(FileState(name, 'symlink', False,
                                        hashlib.sha256(os.fsencode(os.readlink(path))).hexdigest()))
            elif not path.exists():
                result.append(FileState(name, 'missing', False, ''))
            elif path.is_file():
                result.append(FileState(name, 'file', bool(path.stat().st_mode & stat.S_IXUSR),
                                        hashlib.sha256(path.read_bytes()).hexdigest()))
            else:
                raise FlurryError(f'Unsupported directory/file or tracked path obstruction: {path}')
        return tuple(result)

    def _identity(self, repo: Path) -> tuple[tuple[str, str], ...]:
        raw = self._git(repo, 'config', '--null', '--get-regexp',
                        r'^(user\.(name|email|signingkey|useconfigonly)|author\.(name|email)|committer\.(name|email)|commit\.gpgsign|gpg\..*)$',
                        check=False)
        settings = [tuple(item.decode(errors='surrogateescape').split('\n', 1))
                    for item in raw.split(b'\0') if item]
        for kind in ('author', 'committer'):
            ident = self._text(repo, 'var', f'GIT_{kind.upper()}_IDENT')
            match = re.fullmatch(r'(.*) <([^<>]*)> [0-9]+ [+-][0-9]+', ident)
            if match is None:
                raise FlurryError(f'Cannot resolve {kind} identity in {repo}')
            settings.extend([(f'{kind}.name', match[1]), (f'{kind}.email', match[2])])
        return tuple(settings)

    def _capture(self, repo: Path, scratch: Path) -> Snapshot:
        head = self._text(repo, 'rev-parse', 'HEAD')
        branch = self._text(repo, 'symbolic-ref', 'HEAD')
        index = self._text(repo, 'write-tree')
        untracked = self._paths(self._git(repo, 'ls-files', '--others', '--exclude-standard', '-z'))
        for name in untracked:
            if not ((repo / name).is_file() or (repo / name).is_symlink()):
                raise FlurryError(f'Unsupported untracked directory/file in {repo}: {name}')
        with tempfile.TemporaryDirectory(prefix='flurry-index-', dir=scratch) as temporary:
            env = {'GIT_INDEX_FILE': str(Path(temporary) / 'index'), 'GIT_LITERAL_PATHSPECS': '1'}
            self._git(repo, 'read-tree', '--empty', env=env)
            if untracked:
                data = b''.join(os.fsencode(path) + b'\0' for path in untracked)
                self._git(repo, 'add', '--pathspec-from-file=-', '--pathspec-file-nul',
                          input_data=data, env=env)
            untracked_tree = self._text(repo, 'write-tree', env=env)
        return Snapshot(
            head, branch, index,
            self._git(repo, 'diff', '--binary', '--no-ext-diff', '--no-textconv'),
            untracked_tree, untracked,
            self._files(repo, self._tree_paths(repo, head) + self._tree_paths(repo, index) + untracked),
            self._git(repo, 'ls-files', '-v', '-z'),
            self._git(repo, 'stash', 'list', '--format=%H'),
            self._git(repo, 'config', '--null', '--list'), self._identity(repo),
        )

    def _no_gitlinks(self, repo: Path, tree: str) -> None:
        if any(item.startswith(b'160000 ') for item in self._git(repo, 'ls-tree', '-r', '-z', tree).split(b'\0')):
            raise FlurryError(f'Gitlink-bearing parent repositories are unsupported: {repo}')

    def _preflight(self, repo: Path) -> None:
        if not self._succeeds(repo, 'symbolic-ref', '--quiet', 'HEAD'):
            raise FlurryError(f'Detached HEAD in {repo}')
        gitdir = Path(self._text(repo, 'rev-parse', '--absolute-git-dir'))
        for name in ('rebase-merge', 'rebase-apply', 'MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'sequencer', 'BISECT_LOG', 'index.lock'):
            if (gitdir / name).exists():
                raise FlurryError(f'Existing Git operation ({name}) in {repo}')
        if self._git(repo, 'ls-files', '--unmerged'):
            raise FlurryError(f'Unmerged index in {repo}')
        if self._text(repo, 'config', '--bool', 'core.sparseCheckout', check=False) == 'true':
            raise FlurryError(f'Sparse checkout is unsupported: {repo}')
        for entry in self._git(repo, 'ls-files', '-v', '-z').split(b'\0'):
            if entry and (chr(entry[0]).islower() or entry.startswith(b'S')):
                raise FlurryError(f'Special index flags in {repo}; clear assume-unchanged/skip-worktree')
        index = self._text(repo, 'write-tree')
        if self._git(repo, 'ls-files', '-z') != self._git(repo, 'ls-tree', '-r', '--name-only', '-z', index):
            raise FlurryError(f'Intent-to-add entries in {repo}; stage content or unstage first')
        for tree in ('HEAD', index):
            self._no_gitlinks(repo, tree)
            for name in self._tree_paths(repo, tree):
                path = repo / name
                if path.is_dir() and not path.is_symlink():
                    raise FlurryError(f'Directory obstructs original tracked path: {path}')
                for parent in path.parents:
                    if parent == repo:
                        break
                    if parent.is_symlink() or (parent.exists() and not parent.is_dir()):
                        raise FlurryError(f'Physical path obstructs original tracked tree: {parent}')
        for name in self._paths(self._git(repo, 'diff', '--cached', '--no-renames', '--name-only', '--diff-filter=D', '-z', 'HEAD')):
            path = repo / name
            if (path.exists() or path.is_symlink()) and self._succeeds(repo, 'check-ignore', '--quiet', '--no-index', '--', name):
                raise FlurryError(f'Ignored replacement of staged-deleted path: {path}')
        # Source-only filter semantics cannot safely be reproduced under another gitdir.
        if self._git(repo, 'config', '--get-regexp', r'^filter\.', check=False):
            raise FlurryError(f'Git clean/smudge filters are unsupported: {repo}')
        if self._text(repo, 'config', 'core.autocrlf', check=False) not in ('', 'false'):
            raise FlurryError(f'Git EOL conversion may be lossy; core.autocrlf is unsupported: {repo}')
        attributes = Path(self._text(repo, 'rev-parse', '--git-path', 'info/attributes'))
        if not attributes.is_absolute():
            attributes = repo / attributes
        if attributes.exists() and attributes.read_bytes().strip():
            raise FlurryError(f'Source-only info/attributes are unsupported: {repo}')

    def _no_commit_hooks(self, repo: Path) -> None:
        path = self.runner.text(['git', '-C', str(repo), 'rev-parse', '--git-path', 'hooks'], None)
        hooks = Path(path)
        if not hooks.is_absolute():
            hooks = repo / hooks
        for name in ('pre-commit', 'prepare-commit-msg', 'commit-msg', 'post-commit'):
            hook = hooks / name
            if hook.exists() and os.access(hook, os.X_OK):
                raise FlurryError(f'Commit hook requires unsupported isolated execution context: {hook}')

    def _commit(self, prepared: Prepared, message: str) -> None:
        self._no_commit_hooks(prepared.repo)
        self._git(prepared.trial, 'commit', '-m', message,
                  env={'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_CONFIG_NOSYSTEM': '1'})

    def _stash(self, repo: Path, marker: str) -> str:
        path = repo / marker
        if path.exists() or path.is_symlink() or self._succeeds(repo, 'ls-files', '--error-unmatch', '--', marker) or self._succeeds(repo, 'check-ignore', '--quiet', '--no-index', '--', marker):
            raise FlurryError(f'Recovery sentinel collision: {path}')
        path.write_bytes(self._marker_content(marker))
        self._git(repo, 'add', '--', marker, env={'GIT_LITERAL_PATHSPECS': '1'})
        self._git(repo, 'stash', 'push', '--include-untracked', '-m', f'flurry recovery {marker}')
        return self._text(repo, 'rev-parse', 'refs/stash')

    @staticmethod
    def _marker_content(marker: str) -> bytes:
        return f'flurry owned snapshot {marker}\n'.encode()

    def _remove_marker(self, repo: Path, marker: str) -> None:
        path = repo / marker
        content = self._marker_content(marker)
        if not path.is_file() or path.is_symlink() or path.read_bytes() != content or self._git(repo, 'show', f':{marker}') != content:
            raise FlurryError(f'Recovery sentinel changed; refusing removal: {path}')
        self._git(repo, 'rm', '-f', '--', marker)

    def _drop_stash(self, repo: Path, oid: str) -> None:
        for entry in self._text(repo, 'stash', 'list', '--format=%H %gd').splitlines():
            found, ref = entry.split(' ', 1)
            if found == oid:
                self._git(repo, 'stash', 'drop', ref)
                return

    def _check_collisions(self, repo: Path, objects: Path, before: str, after: str,
                          captured: set[str]) -> None:
        for name in self._paths(self._git(objects, 'diff', '--no-renames', '--name-only', '--diff-filter=ACRT', '-z', before, after)):
            if name in captured:
                continue
            candidate = Path(name)
            while str(candidate) != '.':
                path = repo / candidate
                if not self._succeeds(objects, 'cat-file', '-e', f'{before}:{candidate}') and (path.exists() or path.is_symlink()):
                    if str(candidate) == name or not path.is_dir() or path.is_symlink():
                        raise FlurryError(f'Incoming path would overwrite untracked/ignored data: {path}')
                candidate = candidate.parent

    def _collisions(self, prepared: Prepared) -> None:
        captured = set()
        if prepared.dirty_mode == 'commit':
            captured.update(self._tree_paths(prepared.repo, prepared.original.index_tree))
            captured.update(prepared.original.untracked)
        self._check_collisions(prepared.repo, prepared.trial, prepared.original.head, prepared.head, captured)

    def _verify_stash(self, prepared: Prepared, stash: str) -> None:
        original = prepared.original
        if self._text(prepared.repo, 'rev-parse', f'{stash}^1') != original.head or self._text(prepared.repo, 'symbolic-ref', 'HEAD') != original.branch:
            raise FlurryError('Source HEAD/branch changed during capture; actual recovery stash retained')
        with tempfile.TemporaryDirectory(prefix='flurry-stash-check-', dir=prepared.trial.parent) as temporary:
            env = {'GIT_INDEX_FILE': str(Path(temporary) / 'index'), 'GIT_LITERAL_PATHSPECS': '1'}
            self._git(prepared.repo, 'read-tree', original.index_tree, env=env)
            if original.worktree_patch:
                self._git(prepared.repo, 'apply', '--cached', '--binary', input_data=original.worktree_patch, env=env)
            expected_worktree = self._text(prepared.repo, 'write-tree', env=env)
            for tree, expected in ((f'{stash}^2', original.index_tree), (stash, expected_worktree)):
                self._git(prepared.repo, 'read-tree', tree, env=env)
                self._git(prepared.repo, 'update-index', '--force-remove', '--', prepared.marker, env=env)
                if self._text(prepared.repo, 'write-tree', env=env) != expected:
                    raise FlurryError('Source changed during capture; actual captured stash retained')
            if self._text(prepared.repo, 'rev-parse', f'{stash}^3^{{tree}}') != original.untracked_tree:
                raise FlurryError('Source changed during capture; actual captured untracked stash retained')

    def prepare(self, repo: Path, destination: Path, baseline: str, dirty_mode: str,
                message: str | None, commit_scope: str | None, *, remote: str = 'origin') -> Prepared:
        repo, destination = repo.resolve(), destination.absolute()
        if destination.exists():
            raise FlurryError(f'Trial destination must not exist: {destination}')
        if destination == repo or repo in destination.parents:
            raise FlurryError('Trial destination must be outside the source worktree')
        if dirty_mode not in ('reject', 'preserve', 'commit'):
            raise FlurryError(f'Unknown dirty mode: {dirty_mode}')
        if dirty_mode == 'commit' and (not message or commit_scope not in ('staged', 'all')):
            raise FlurryError('Dirty commit requires a message and explicit staged/all scope')
        if dirty_mode != 'commit' and (message is not None or commit_scope is not None):
            raise FlurryError('Commit message/scope only apply to dirty commit mode')
        self._preflight(repo)
        url = self._text(repo, 'remote', 'get-url', remote)
        if not url or url.startswith('-') or url.startswith('ext::'):
            raise FlurryError(f'Unsupported or empty remote URL in {repo}')
        ref = baseline if baseline.startswith('refs/heads/') else f'refs/heads/{baseline}'
        if not self._succeeds(repo, 'check-ref-format', ref):
            raise FlurryError(f'Invalid baseline branch: {baseline}')
        destination.parent.mkdir(parents=True, exist_ok=True)
        original = self._capture(repo, destination.parent)
        dirty = bool(self._git(repo, 'status', '--porcelain', '--untracked-files=all'))
        if dirty_mode == 'reject' and dirty:
            raise FlurryError(f'Dirty source rejected: {repo}')
        self.runner.run(['git', '-c', 'core.fsmonitor=false', 'clone', '--quiet', '--local', '--no-hardlinks', '--no-checkout', '--', str(repo), str(destination)], None)
        self._git(destination, 'config', 'core.fsmonitor', 'false')
        for key, value in original.identity:
            self._git(destination, 'config', '--local', '--replace-all', key, value)
        self._git(destination, 'remote', 'set-url', 'origin', url)
        self._git(destination, 'read-tree', original.index_tree)
        self._git(destination, 'checkout-index', '--all', '--force')
        if original.worktree_patch:
            self._git(destination, 'apply', '--binary', input_data=original.worktree_patch)
        with tempfile.TemporaryDirectory(prefix='flurry-checkout-', dir=destination.parent) as temporary:
            env = {'GIT_INDEX_FILE': str(Path(temporary) / 'index')}
            self._git(destination, 'read-tree', original.untracked_tree, env=env)
            self._git(destination, 'checkout-index', '--all', env=env)
        if self._files(destination, tuple(item.path for item in original.files)) != original.files:
            raise FlurryError(f'Source content does not roundtrip losslessly in rehearsal: {repo}')
        marker = f'.flurry-{uuid.uuid4().hex}'
        prepared = Prepared(repo, destination, original, original.head, '', original.branch,
                            remote, url, '', marker, dirty_mode)
        if dirty_mode == 'commit' and dirty:
            if commit_scope == 'all':
                self._git(destination, 'add', '--all')
            if self._text(destination, 'write-tree') != self._text(destination, 'rev-parse', 'HEAD^{tree}'):
                self._commit(prepared, message)
        remaining_paths = set(self._paths(self._git(destination, 'diff', 'HEAD', '--name-only', '-z')))
        remaining_paths.update(self._paths(self._git(destination, 'ls-files', '--others', '--exclude-standard', '-z')))
        if remaining_paths.intersection({'flake.nix', 'flake.lock'}):
            raise FlurryError(f'Preserved user flake.nix/flake.lock edits overlap lock generation: {repo}')
        prepared.remaining_stash = self._stash(destination, marker)
        self._git(destination, 'fetch', '--no-recurse-submodules', 'origin', f'+{ref}:refs/flurry/baseline')
        prepared.baseline = self._text(destination, 'rev-parse', 'refs/flurry/baseline')
        try:
            self._git(destination, '-c', 'core.editor=true', 'rebase', '--no-autostash', '--no-update-refs', 'refs/flurry/baseline',
                      env={'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_CONFIG_NOSYSTEM': '1'})
        except FlurryError as error:
            raise FlurryError(f'Rebase rehearsal failed; originals unchanged: {error}') from error
        prepared.head = self._text(destination, 'rev-parse', 'HEAD')
        self._no_gitlinks(destination, prepared.head)
        self.rehearse_restore(prepared)
        return prepared

    def verify(self, prepared: Prepared) -> None:
        self._preflight(prepared.repo)
        if self._capture(prepared.repo, prepared.trial.parent) != prepared.original or self._text(prepared.repo, 'remote', 'get-url', prepared.remote) != prepared.remote_url:
            raise FlurryError(f'Source changed during rehearsal: {prepared.repo}')

    def rehearse_restore(self, prepared: Prepared) -> None:
        if self._text(prepared.trial, 'rev-parse', 'HEAD') != prepared.head or self._git(prepared.trial, 'status', '--porcelain'):
            raise FlurryError('Restore rehearsal requires a clean trial at the prepared commit')
        self._collisions(prepared)
        try:
            self._git(prepared.trial, 'stash', 'apply', '--index', prepared.remaining_stash)
            self._remove_marker(prepared.trial, prepared.marker)
        except FlurryError as error:
            raise FlurryError(f'Dirty restore rehearsal failed; originals unchanged: {error}') from error
        prepared.restored = self._capture(prepared.trial, prepared.trial.parent)
        # Destructive writes below are confined to our disposable trial and captured paths.
        self._git(prepared.trial, 'reset', '--hard', '--no-recurse-submodules', prepared.head)
        self._remove_untracked(prepared.trial, prepared.restored.untracked)

    def _remove_untracked(self, repo: Path, paths: tuple[str, ...]) -> None:
        for name in paths:
            path = repo / name
            for parent in path.parents:
                if parent == repo:
                    break
                if parent.is_symlink():
                    raise FlurryError(f'Refusing untracked removal through a symlink: {path}')
            if path.is_file() or path.is_symlink():
                path.unlink()
            elif path.exists():
                raise FlurryError(f'Refusing to remove non-file recovery path: {path}')

    def commit_lock(self, prepared: Prepared, message: str = 'Update flake.lock') -> None:
        if self._text(prepared.trial, 'rev-parse', 'HEAD') != prepared.head:
            raise FlurryError('Trial HEAD changed before lock commit')
        changed = set(self._paths(self._git(prepared.trial, 'diff', 'HEAD', '--name-only', '-z')))
        changed.update(self._paths(self._git(prepared.trial, 'ls-files', '--others', '--exclude-standard', '-z')))
        if changed - {'flake.lock'}:
            raise FlurryError('Lock generation changed paths other than flake.lock')
        if changed:
            self._git(prepared.trial, 'add', '--', 'flake.lock')
            self._commit(prepared, message)
            prepared.head = self._text(prepared.trial, 'rev-parse', 'HEAD')
            prepared.restored = None

    def promote(self, prepared: Prepared, run_id: str) -> Recovery:
        if re.fullmatch(r'[A-Za-z0-9_-]+', run_id) is None:
            raise FlurryError('Invalid recovery run identifier')
        self.verify(prepared)
        self.rehearse_restore(prepared)
        suffix = hashlib.sha256(str(prepared.repo).encode()).hexdigest()[:16]
        prefix = f'refs/flurry/{run_id}/{suffix}'
        record = Recovery(prepared, f'{prefix}/stash', f'{prefix}/prepared', '', None, 'untouched')
        for ref in (record.stash_ref, record.prepared_ref):
            if self._succeeds(prepared.repo, 'show-ref', '--verify', '--quiet', ref):
                raise FlurryError(f'Recovery ref already exists: {ref}')
        self._git(prepared.repo, 'fetch', '--no-tags', '--no-recurse-submodules', str(prepared.trial),
                  f'{prepared.remaining_stash}:{prefix}/remaining', f'{prepared.head}:{record.prepared_ref}')
        self.verify(prepared)
        try:
            record.phase = 'stashing'
            record.original_stash = self._stash(prepared.repo, prepared.marker)
            self._git(prepared.repo, 'update-ref', record.stash_ref, record.original_stash)
            record.phase = 'captured'
            self._verify_stash(prepared, record.original_stash)
            # Checkout is restricted to the verified source, captured by the owned recovery stash.
            self._git(prepared.repo, 'checkout', '--no-recurse-submodules', '--no-overwrite-ignore', '-B', prepared.branch.removeprefix('refs/heads/'), prepared.head)
            record.phase = 'checked-out'
            restore = record.original_stash if prepared.dirty_mode != 'commit' else f'{prefix}/remaining'
            self._git(prepared.repo, 'stash', 'apply', '--index', restore)
            self._remove_marker(prepared.repo, prepared.marker)
            self._drop_stash(prepared.repo, record.original_stash)
            observed = self._capture(prepared.repo, prepared.trial.parent)
            expected = prepared.restored
            if expected is None:
                raise FlurryError('Missing restore rehearsal postcondition')
            fields = ('head', 'branch', 'index_tree', 'worktree_patch', 'untracked_tree', 'untracked', 'files', 'flags')
            if any(getattr(observed, field) != getattr(expected, field) for field in fields) or observed.stashes != prepared.original.stashes or observed.config != prepared.original.config or observed.identity != prepared.original.identity:
                raise FlurryError('Promotion postcondition changed; refusing ownership of unexpected edits')
            record.promoted = observed
            record.phase = 'promoted'
            return record
        except FlurryError as error:
            raise PromotionError(f'Promotion failed; recovery artifacts retained under {prefix}: {error}', record) from error

    def recover(self, record: Recovery) -> None:
        prepared = record.prepared
        repo = prepared.repo
        # An incomplete checkout/restore may contain uncaptured concurrent edits: never guess.
        if record.phase != 'promoted' or record.promoted is None:
            raise FlurryError(f'Ambiguous incomplete promotion; manual recovery required using {record.stash_ref}')
        self._preflight(repo)
        if self._capture(repo, prepared.trial.parent) != record.promoted:
            raise FlurryError(f'Source changed since promotion; refusing destructive recovery: {repo}')
        if self._text(repo, 'show', f'{record.stash_ref}^2:{prepared.marker}') != self._marker_content(prepared.marker).decode().strip():
            raise FlurryError('Recovery stash sentinel does not match')
        self._check_collisions(repo, repo, record.promoted.head, prepared.original.head, set())
        # Only our exact promoted state may be reset; never clean or recurse into children.
        self._git(repo, 'reset', '--hard', '--no-recurse-submodules', prepared.original.head)
        self._remove_untracked(repo, record.promoted.untracked)
        self._git(repo, 'stash', 'apply', '--index', record.stash_ref)
        self._remove_marker(repo, prepared.marker)
        if self._capture(repo, prepared.trial.parent) != prepared.original:
            raise FlurryError(f'Recovery postcondition failed; retain {record.stash_ref}')
        record.phase = 'recovered'

    def push(self, repo: Path, remote: str, destination_ref: str, expected_oid: str) -> None:
        if not destination_ref.startswith('refs/heads/') or not self._succeeds(repo, 'check-ref-format', destination_ref):
            raise FlurryError(f'Invalid push branch: {destination_ref}')
        if self._text(repo, 'rev-parse', 'HEAD') != expected_oid or re.fullmatch(r'[0-9a-f]{40,64}', expected_oid) is None:
            raise FlurryError(f'HEAD changed before push: {repo}')
        # Ordinary source push hooks are honored; force and recursive submodule pushes are forbidden.
        self.runner.run(['git', '-C', str(repo), '-c', 'submodule.recurse=false', 'push',
                         '--recurse-submodules=no', '--', remote, f'{expected_oid}:{destination_ref}'], None)
        advertised = self.runner.git_text(repo, 'ls-remote', '--refs', '--', remote, destination_ref)
        if advertised != f'{expected_oid}\t{destination_ref}':
            raise FlurryError(f'Remote verification failed after push: {repo} {destination_ref}')
