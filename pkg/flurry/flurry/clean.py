from __future__ import annotations

import hashlib
import os
import re
import stat
from dataclasses import dataclass
from pathlib import Path

from .process import FlurryError, Runner


REFS = ('--glob=refs/stas[h]', '--symbolic-full-name', 'HEAD', '--glob=refs/stas[h]', '--glob=refs/replace/*')
OPERATIONS = ('rebase-merge', 'rebase-apply', 'MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD',
              'sequencer', 'BISECT_LOG', 'index.lock', 'commondir', 'info/grafts')
IDENTITY_KEYS = re.compile(r'user\.(name|email|signingkey|useconfigonly)|(?:author|committer)\.(name|email)|commit\.gpgsign|gpg\..*')
INERT_ATTRIBUTE_LINE = re.compile(rb'(?:#[ -~]*|[a-zA-Z0-9_.*][a-zA-Z0-9_./*-]* +(?:-whitespace|binary))?')
MERGE_ATTRIBUTE_LINE = re.compile(rb'(?:#[ -~]*|[a-zA-Z0-9_.*][a-zA-Z0-9_./*+-]*[ \t]+merge=[a-zA-Z0-9_][a-zA-Z0-9_.-]*)?')


def config_values(repo: Path, runner: Runner) -> bytes:
    return runner.run(['git', '-C', str(repo), 'config', '--show-scope', '--null', '--list'], None)


def unscoped(raw: bytes) -> bytes:
    return b''.join(record + b'\0' for record in raw.split(b'\0')[1::2])


def settings(raw: bytes) -> dict[str, str]:
    return {key: value for record in os.fsdecode(unscoped(raw)).split('\0') if record
            for key, _, value in (record.partition('\n'),)}


def pack(values) -> bytes:
    digest = hashlib.sha256()
    for value in values:
        digest.update(len(value).to_bytes(8, 'big'))
        digest.update(value)
    return digest.digest()


def file_guard(paths: tuple[Path, ...]) -> bytes | None:
    values = []
    for path in paths:
        if path == Path('/dev/null') or not path.exists():
            values.append(b'-')
        elif path.is_file():
            values.append(b'+' + path.read_bytes())
        else:
            return None
    return pack(values)


def physical_file(path: Path, *, git_hash: str | None = None) -> tuple[bytes, bytes, bytes | None]:
    try:
        st = path.lstat()
    except (FileNotFoundError, NotADirectoryError):
        return b'missing', b'', None
    if stat.S_ISLNK(st.st_mode):
        mode, target = b'120000', os.fsencode(os.readlink(path))
        size = len(target)
    elif stat.S_ISREG(st.st_mode):
        mode, target, size = b'100755' if st.st_mode & stat.S_IXUSR else b'100644', None, st.st_size
    else:
        return b'obstructed', b'', None
    blob = hashlib.new(git_hash, b'blob ' + str(size).encode() + b'\0') if git_hash else None
    physical = hashlib.sha256()
    if target is not None:
        physical.update(target)
        if blob is not None:
            blob.update(target)
    else:
        with path.open('rb') as source:
            while chunk := source.read(1024 * 1024):
                physical.update(chunk)
                if blob is not None:
                    blob.update(chunk)
    return mode, physical.digest(), blob.hexdigest().encode() if blob else None


def ordinary_layout(repo: Path) -> bool:
    gitdir = repo / '.git'
    if gitdir.is_symlink() or not gitdir.is_dir() or any(os.path.lexists(gitdir / path) for path in ('commondir', 'remotes')):
        return False
    branches = gitdir / 'branches'
    if os.path.lexists(branches) and (branches.is_symlink() or not branches.is_dir() or any(branches.iterdir())):
        return False
    return True


@dataclass(frozen=True)
class MergeAttributes:
    path: Path
    target: Path
    contents: bytes

    @classmethod
    def read(cls, path: Path) -> MergeAttributes | None:
        try:
            target = path.resolve(strict=True)
            if not target.is_file():
                return None
            descriptor = os.open(target, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
            with os.fdopen(descriptor, 'rb') as source:
                if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
                    return None
                data = source.read(65537)
            if len(data) > 65536 or not all(MERGE_ATTRIBUTE_LINE.fullmatch(row) for row in data.split(b'\n')):
                return None
            return cls(path, target, data)
        except (OSError, RuntimeError):
            return None

    @property
    def fingerprint(self) -> bytes:
        return pack((os.fsencode(self.path), os.fsencode(self.target), self.contents))


@dataclass(frozen=True)
class Context:
    repo: Path
    config: bytes
    identity: tuple[tuple[str, str], ...]
    attrs: tuple[Path, ...]
    config_paths: tuple[Path, ...]
    guard: bytes | None
    merge_attributes: MergeAttributes | None

    @classmethod
    def inspect(cls, repo: Path, runner: Runner) -> Context | None:
        gitdir = repo / '.git'
        if not ordinary_layout(repo):
            return None
        if any(runner.environment.get(key) for key in ('GIT_CONFIG', 'GIT_ATTR_SOURCE', 'GIT_REPLACE_REF_BASE', 'GIT_GRAFT_FILE', 'GIT_SHALLOW_FILE')):
            return None
        if any('\n' in value for key, value in runner.environment.items() if key.startswith(('GIT_', 'XDG_')) or key in ('HOME', 'EMAIL', 'PAGER', 'EDITOR', 'VISUAL')):
            return None
        variables: dict[str, list[str]] = {}
        listing = runner.run(['git', '-C', str(repo), 'var', '-l'], None)
        for line in os.fsdecode(listing).removesuffix('\n').split('\n'):
            key, _, value = line.partition('=')
            if key.startswith('GIT_'):
                variables.setdefault(key, []).append(value)
        config_paths = tuple(Path(name) for key in ('GIT_CONFIG_GLOBAL', 'GIT_CONFIG_SYSTEM')
                             for name in variables.get(key, ())) + (gitdir / 'config', gitdir / 'config.worktree')
        guard = file_guard(config_paths) if (variables.get('GIT_CONFIG_GLOBAL') and (variables.get('GIT_CONFIG_SYSTEM')
                or runner.environment.get('GIT_CONFIG_NOSYSTEM') == '1') and all(path.is_absolute() for path in config_paths)) else None
        raw = config_values(repo, runner)
        records = unscoped(raw).split(b'\0')
        rendered = b''.join(row.replace(b'\n', b'=', 1) + b'\n' for row in records if row)
        if not listing.startswith(rendered) or any(b'\n' in row.partition(b'\n')[2] for row in records):
            return None
        if any(not re.fullmatch(rb'GIT_[A-Z0-9_]+=.*', row) for row in listing[len(rendered):].removesuffix(b'\n').split(b'\n')):
            return None
        values = settings(raw)
        if (any(key.startswith(('extensions.', 'filter.unset.', 'filter.unspecified.')) for key in values)
                or any(key in values for key in ('core.worktree', 'core.attributesfile', 'attr.tree', 'core.sparsecheckout', 'core.splitindex'))
                or values.get('core.autocrlf', 'false') != 'false'):
            return None
        if any(key.startswith(('include.', 'includeif.')) for key in values):
            guard = None
        identity = {key: value for key, value in values.items() if IDENTITY_KEYS.fullmatch(key)}
        for kind in ('author', 'committer'):
            if not all(runner.environment.get(f'GIT_{kind}_{field}'.upper()) or values.get(f'{kind}.{field}') or values.get(f'user.{field}')
                       for field in ('name', 'email')):
                return None
            var = variables.get(f'GIT_{kind.upper()}_IDENT', [])
            if len(var) != 1 or not (match := re.fullmatch(r'(.*) <([^<>]*)> [0-9]+ [+-][0-9]+', var[0])):
                return None
            identity[kind + '.name'], identity[kind + '.email'] = match.groups()
        paths = [gitdir / 'info/attributes']
        merge_attributes = None
        for key in ('GIT_ATTR_GLOBAL', 'GIT_ATTR_SYSTEM'):
            var = variables.get(key, [])
            if key == 'GIT_ATTR_SYSTEM' and runner.environment.get('GIT_ATTR_NOSYSTEM') == '1':
                continue
            if len(var) != 1 or not Path(var[0]).is_absolute():
                return None
            path = Path(var[0])
            if key == 'GIT_ATTR_GLOBAL' and os.path.lexists(path):
                merge_attributes = MergeAttributes.read(path)
                if merge_attributes is None:
                    return None
            else:
                paths.append(path)
        return cls(repo, raw, tuple(identity.items()), tuple(paths), config_paths, guard, merge_attributes)

    def may_ignore_marker(self, runner: Runner) -> bool:
        if 'core.excludesfile' in settings(self.config) or os.path.lexists(self.repo / '.gitignore'):
            return True
        directory = runner.environment.get('XDG_CONFIG_HOME') or str(Path(runner.environment.get('HOME', '')) / '.config')
        if not Path(directory).is_absolute() or os.path.lexists(Path(directory) / 'git/ignore'):
            return True
        exclude = self.repo / '.git/info/exclude'
        return exclude.exists() and (not exclude.is_file() or any(line and not line.startswith(b'#') for line in exclude.read_bytes().split(b'\n')))

    def config_matches(self, runner: Runner) -> bool:
        return ordinary_layout(self.repo) and (self.guard is not None and file_guard(self.config_paths) == self.guard
                                               or config_values(self.repo, runner) == self.config)

    def valid(self, runner: Runner) -> bool:
        gitdir = self.repo / '.git'
        if any(os.path.lexists(gitdir / name) for name in OPERATIONS):
            return False
        if any(os.path.lexists(path) for path in self.attrs):
            return False
        if self.merge_attributes is not None and MergeAttributes.read(self.merge_attributes.path) != self.merge_attributes:
            return False
        return self.config_matches(runner)


@dataclass(frozen=True)
class Manifest:
    entries: dict[str, tuple[bytes, bytes]]
    attributes: tuple[str, ...]
    index: bytes
    has_empty_blob: bool

    @classmethod
    def load(cls, repo: Path, runner: Runner, tree: str) -> Manifest | None:
        entries = {}
        directories = {'.'}
        attribute_blobs = set()
        index = []
        empty = hashlib.new('sha1' if len(tree) == 40 else 'sha256', b'blob 0\0').hexdigest().encode()
        for item in runner.git(repo, '--no-replace-objects', 'ls-tree', '-r', '-z', tree).split(b'\0'):
            if not item:
                continue
            metadata, name = item.split(b'\t', 1)
            mode, kind, oid = metadata.split()
            path = Path(os.fsdecode(name))
            if (kind != b'blob' or mode not in (b'100644', b'100755', b'120000') or path.is_absolute() or not path.parts
                    or os.fsencode(path) != name or str(path) in entries or '..' in path.parts or '.git' in path.parts
                    or any(part.lower() == '.gitattributes' for part in path.parts[:-1])
                    or (path.name.lower() == '.gitattributes' and (path.name != '.gitattributes' or mode == b'120000'))
                    or (str(path) in ('flake.nix', 'flake.lock') and mode == b'120000')):
                return None
            if path.name == '.gitattributes':
                attribute_blobs.add(oid)
            entries[str(path)] = (mode, oid)
            directories.update(map(str, path.parents))
            index.append(b'H ' + mode + b' ' + oid + b' 0\t' + name + b'\0')
        if not directories.isdisjoint(entries):
            return None
        for oid in attribute_blobs:
            rules = runner.git(repo, '--no-replace-objects', 'cat-file', 'blob', os.fsdecode(oid))
            if not all(INERT_ATTRIBUTE_LINE.fullmatch(line) for line in rules.split(b'\n')):
                return None
        return cls(entries, tuple(str(Path(p) / '.gitattributes') for p in directories), b''.join(sorted(index, key=lambda row: row.split(b'\t', 1)[1])),
                   any(oid == empty for _, oid in entries.values()))

    def contents(self, repo: Path, *, except_lock: bool = False, prove_blobs: bool = False) -> dict[str, bytes] | None:
        if any(name not in self.entries and os.path.lexists(repo / name) for name in self.attributes):
            return None
        if any(name not in self.entries and os.path.lexists(repo / name)
               for name in (('flake.nix',) if except_lock else ('flake.nix', 'flake.lock'))):
            return None
        values = {}
        for name, (mode, expected) in self.entries.items():
            if except_lock and name == 'flake.lock':
                continue
            path = repo / name
            if any((repo / parent).is_symlink() for parent in path.relative_to(repo).parents if parent != Path('.')):
                return None
            observed_mode, digest, oid = physical_file(path, git_hash=('sha1' if len(expected) == 40 else 'sha256') if prove_blobs else None)
            if observed_mode != mode or (prove_blobs and oid != expected):
                return None
            values[name] = digest
        return values


@dataclass(frozen=True)
class CheckoutRefs:
    head: str
    tree: str
    branch: str
    stash: str = ''

    @classmethod
    def parse(cls, rows: tuple[str, ...]) -> CheckoutRefs | None:
        if len(rows) == 3 and rows[2].startswith('refs/heads/'):
            return cls(*rows)
        if len(rows) == 5 and rows[3].startswith('refs/heads/') and rows[4] == 'refs/stash' and re.fullmatch(r'[a-f0-9]{40}|[a-f0-9]{64}', rows[2]):
            return cls(rows[0], rows[1], rows[3], rows[2])
        return None


def stash_layout(repo: Path, present: bool) -> bool:
    gitdir = repo / '.git'
    if any((gitdir / name).is_symlink() for name in ('refs', 'logs', 'logs/refs', 'packed-refs')):
        return False
    ref, log = gitdir / 'refs/stash', gitdir / 'logs/refs/stash'
    if present:
        return ((not os.path.lexists(ref) or (not ref.is_symlink() and ref.is_file()))
                and not log.is_symlink() and log.is_file())
    return not os.path.lexists(ref) and not os.path.lexists(log)


@dataclass(frozen=True)
class CleanCheckout:
    head: str
    tree: str
    branch: str
    context: Context
    manifest: Manifest
    physical: dict[str, bytes]
    stashes: bytes = b''

    @property
    def checkpoint(self) -> str:
        checkout = pack((os.fsencode(self.head), os.fsencode(self.branch), os.fsencode(self.tree), pack(self.physical.values()),
                         self.context.config, *(os.fsencode(value) for pair in self.context.identity for value in pair)))
        attrs = self.context.merge_attributes
        if not self.stashes and attrs is None:
            return 'clean-v1:' + checkout.hex()
        return 'clean-v2:' + pack((checkout, self.stashes, attrs.fingerprint if attrs else b'')).hex()

    def matches(self, repo: Path, runner: Runner, *, known_refs: bool = False, known_contents: bool = False, except_lock: bool = False) -> bool:
        if repo != self.context.repo or not self.context.valid(runner):
            return False
        observed = runner.git(repo, '--no-optional-locks', '-c', 'core.fsmonitor=false', '-c', 'core.untrackedCache=false',
                              'ls-files', '--cached', '--stage', '-v', '--others', '--exclude-standard', '-z')
        expected = self.manifest.index
        if except_lock:
            def without_lock(index):
                return [row for row in index.split(b'\0') if not ((row.startswith((b'H 100644 ', b'H 100755 '))
                        and row.partition(b'\t')[2] == b'flake.lock' and row.partition(b'\t')[0].endswith(b' 0')) or row == b'? flake.lock')]
            if without_lock(observed) != without_lock(expected):
                return False
        elif observed != expected:
            return False
        if self.manifest.has_empty_blob and runner.git(repo, '--no-optional-locks', 'diff-index', '--cached', '--ita-invisible-in-index', '--raw', self.head,
                                                       '--', *([':(exclude,top,literal)flake.lock'] if except_lock else [])):
            return False
        if not known_contents:
            expected_files = {key: value for key, value in self.physical.items() if key != 'flake.lock'} if except_lock else self.physical
            if self.manifest.contents(repo, except_lock=except_lock) != expected_files:
                return False
        if not stash_layout(repo, bool(self.stashes)):
            return False
        if self.stashes and runner.git(repo, 'stash', 'list', '--format=%H') != self.stashes:
            return False
        expected_refs = CheckoutRefs(self.head, self.tree, self.branch, self.stashes.partition(b'\n')[0].decode('ascii'))
        return (known_refs and not self.stashes) or (self.context.valid(runner) and refs(repo, runner) == expected_refs)


def checkout_head(repo: Path, runner: Runner) -> tuple[str, str, str]:
    rows = os.fsdecode(runner.git(repo, 'rev-parse', 'HEAD', 'HEAD^{tree}', '--symbolic-full-name', 'HEAD')).removesuffix('\n').split('\n')
    if len(rows) == 2:
        rows.append(os.fsdecode(runner.git(repo, 'symbolic-ref', 'HEAD')).removesuffix('\n'))
    if len(rows) != 3 or not rows[2].startswith('refs/heads/'):
        raise FlurryError(f'Detached or ambiguous HEAD in {repo}')
    return rows[0], rows[1], rows[2]


def refs(repo: Path, runner: Runner) -> CheckoutRefs | None:
    return CheckoutRefs.parse(tuple(os.fsdecode(runner.git(repo, 'rev-parse', 'HEAD', 'HEAD^{tree}', *REFS)).removesuffix('\n').split('\n')))


def clean_checkout(repo: Path, runner: Runner, *, context: Context | None = None, observed: CheckoutRefs | None = None) -> CleanCheckout | None:
    observed = refs(repo, runner) if observed is None else observed
    if observed is None or not stash_layout(repo, bool(observed.stash)):
        return None
    context = context or Context.inspect(repo, runner)
    if context is None or context.repo != repo or not context.valid(runner):
        return None
    manifest = Manifest.load(repo, runner, observed.tree)
    if manifest is None or (physical := manifest.contents(repo, prove_blobs=True)) is None:
        return None
    stashes = b''
    if observed.stash:
        stashes = runner.git(repo, 'stash', 'list', '--format=%H')
        if (not stashes.startswith(observed.stash.encode('ascii') + b'\n')
                or not re.fullmatch(rb'(?:[a-f0-9]{' + str(len(observed.head)).encode() + rb'}\n)+', stashes)):
            return None
    witness = CleanCheckout(observed.head, observed.tree, observed.branch, context, manifest, physical, stashes)
    return witness if witness.matches(repo, runner, known_refs=True, known_contents=True) else None
