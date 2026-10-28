#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class FlakeRootTests(unittest.TestCase):
    def setUp(self):
        (ROOT / 'debug').mkdir(exist_ok=True)
        directory = tempfile.TemporaryDirectory(prefix='flake-root-', dir=ROOT / 'debug')
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)
        self.public = self.directory / 'public checkout'
        self.private = self.directory / 'configuration checkout'
        self.caller = self.directory / 'unrelated cwd'
        self.bin = self.directory / 'bin'
        for path in (self.public, self.private, self.caller, self.bin):
            path.mkdir()
        self.log = self.directory / 'commands.jsonl'
        self.env = os.environ | {
            'HOME': str(self.directory), 'XDG_STATE_HOME': str(self.directory / 'state'),
            'PATH': f'{self.bin}:{os.environ["PATH"]}',
            'NIX_CONFIG_FLAKE_DIR': str(self.private), 'NIX_CONFIG_DEV_SHELL': '1',
            'GIT_CONFIG_GLOBAL': os.devnull, 'GIT_CONFIG_NOSYSTEM': '1',
            'GIT_ALLOW_PROTOCOL': 'file', 'GIT_AUTHOR_NAME': 'Fixture',
            'GIT_AUTHOR_EMAIL': 'fixture@example.invalid', 'GIT_COMMITTER_NAME': 'Fixture',
            'GIT_COMMITTER_EMAIL': 'fixture@example.invalid',
            'TEST_LOG': str(self.log), 'TEST_PACKAGE': str(self.directory / 'package'),
            'TEST_PUBLIC': str(self.public), 'TEST_OS': 'Linux', 'TEST_HOST': 'fixture',
            'TEST_BOUNDARY_LOG': str(self.directory / 'boundaries.jsonl'),
            'TEST_REAL_MKDIR': shutil.which('mkdir'), 'TEST_REAL_READLINK': shutil.which('readlink'),
            'TEST_REAL_RM': shutil.which('rm'), 'TEST_REAL_TOUCH': shutil.which('touch'),
        }
        package = self.directory / 'package/bin'
        package.mkdir(parents=True)
        (package / 'switch-home').write_text('#!/usr/bin/env bash\nexit 0\n')
        (package / 'switch-home').chmod(0o755)
        for script in ('setup', 'verify-configs', 'verify-kanata-configs', 'switch-hm', 'edit-secret', 'update-masterkeys', 'takeover-host', 'switch', 'switch-darwin'):
            shutil.copy2(ROOT / script, self.public / script)
        for repo in (self.public, self.private):
            self.git('init', '--initial-branch=main', cwd=repo)
            (repo / 'flake.nix').write_text('{}\n')
            self.git('add', '.', cwd=repo)
            self.git('commit', '-m', 'initial', cwd=repo)
        (self.private / 'setup-env').write_text('export ROOT_ENV_LOADED=selected\n')
        (self.public / 'dirty-public').write_text('public dirty\n')
        (self.private / 'dirty-private').write_text('private dirty\n')
        for name, body in {
            'nix': '''import json, os, pathlib, subprocess, sys
args = sys.argv[1:]
with open(os.environ['TEST_LOG'], 'a') as log:
    print(json.dumps(dict(cwd=os.getcwd(), args=args, loaded=os.environ.get('ROOT_ENV_LOADED'))), file=log)
command = next(arg for arg in args if arg in ('eval', 'develop', 'build', 'run', 'flake', 'copy'))
if command == 'flake' and 'metadata' in args:
    print(json.dumps({'originalUrl': 'git+' + pathlib.Path.cwd().as_uri()}))
if command == 'develop':
    if os.environ.get('TEST_STOP_DEVSHELL'):
        sys.exit(0)
    sys.exit(subprocess.run(args[args.index('--command') + 1:]).returncode)
if command == 'eval':
    target = next((arg for arg in args if '#' in arg), '')
    if target.endswith('#homeMeta'):
        print(json.dumps({'alice@fixture-x86_64': dict(hostname='fixture', username='alice', platform='linux')}))
    elif target.endswith('#hostMeta'):
        print(os.environ.get('TEST_SYSTEM_META', json.dumps({'fixture': dict(platform='linux', group='fixture', owner='alice', fqn=None)})))
    elif target.endswith('#nixosConfigurations'):
        print('["fixture"]')
    elif target.endswith('#darwinConfigurations'):
        print('[]')
    elif target.endswith('.config'):
        print('{}')
    elif '--expr' in args:
        print(os.environ['TEST_PUBLIC'])
if command == 'build' and '--out-link' in args:
    target = pathlib.Path(args[args.index('--out-link') + 1])
    if str(target).startswith(os.environ['HOME']):
        target.symlink_to(os.environ['TEST_PACKAGE'])
''',
            'hostname': "import os\nprint(os.environ['TEST_HOST'])\n",
            'uname': "import os, sys\nprint('x86_64' if sys.argv[1:] == ['-m'] else os.environ['TEST_OS'])\n",
            'id': "print('alice')\n",
        }.items():
            executable = self.bin / name
            executable.write_text(f'#!{sys.executable}\n{body}')
            executable.chmod(0o755)

        boundary = self.bin / 'boundary'
        boundary.write_text(f'#!{sys.executable}\n' + """import json, os, pathlib, sys
with open(os.environ['TEST_BOUNDARY_LOG'], 'a') as log:
    print(json.dumps(dict(command=pathlib.Path(sys.argv[0]).name,cwd=os.getcwd(),args=sys.argv[1:],loaded=os.environ.get('ROOT_ENV_LOADED'))),file=log)
""")
        boundary.chmod(0o755)
        for name in ('sudo', 'ssh', 'agenix', 'kanata'):
            (self.bin / name).symlink_to(boundary)
        darwin = self.directory / 'package/sw/bin/darwin-rebuild'
        darwin.parent.mkdir(parents=True)
        darwin.symlink_to(boundary)
        for name, body in {
            'mkdir': "import os, sys\nif any(arg.startswith('/nix/var/nix/gcroots/') for arg in sys.argv[1:]): sys.exit(0)\nos.execv(os.environ['TEST_REAL_MKDIR'], ['mkdir', *sys.argv[1:]])\n",
            'readlink': "import os, sys\nif any(arg.startswith('/nix/var/nix/gcroots/') for arg in sys.argv[1:]): print(os.environ['TEST_PACKAGE'])\nelse: os.execv(os.environ['TEST_REAL_READLINK'], ['readlink', *sys.argv[1:]])\n",
            'rm': "import os, sys\nif any(arg.startswith('/run/attic-push/') for arg in sys.argv[1:]): sys.exit(0)\nos.execv(os.environ['TEST_REAL_RM'], ['rm', *sys.argv[1:]])\n",
            'touch': "import os, sys\nif any(arg.startswith('/run/attic-push/') for arg in sys.argv[1:]): sys.exit(0)\nos.execv(os.environ['TEST_REAL_TOUCH'], ['touch', *sys.argv[1:]])\n",
            'age': "import pathlib,sys\nargs=sys.argv[1:]\npathlib.Path(args[args.index('-o')+1]).write_text('synthetic decrypted key\\n')\n",
            'age-keygen': "print('synthetic public identity')\n",
        }.items():
            executable = self.bin / name
            executable.write_text(f'#!{sys.executable}\n{body}')
            executable.chmod(0o755)

    def git(self, *args, cwd):
        return subprocess.run(['git', *args], cwd=cwd, env=self.env, text=True,
                              capture_output=True, check=True).stdout.strip()

    def invoke(self, script, *args, overrides=None):
        return subprocess.run([str(self.public / script), *args], cwd=self.caller,
                              env=self.env | (overrides or {}), text=True, capture_output=True)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def public_state(self):
        return (self.git('rev-parse', 'HEAD', cwd=self.public),
                self.git('status', '--porcelain', cwd=self.public))

    def test_setup_bootstraps_and_loads_environment_from_selected_root(self):
        self.assert_success(self.invoke('setup', '--offline', '--hm-only', '-n', '-nc', '-nrs',
                                        overrides={'NIX_CONFIG_DEV_SHELL': ''}))
        calls = self.calls()
        self.assertIn('develop', calls[0]['args'])
        self.assertTrue(all(call['cwd'] == str(self.private) for call in calls))
        self.assertTrue(all(call['loaded'] == 'selected' for call in calls[1:]))
        self.assertIn('dirty-private', self.git('diff', '--cached', '--name-only', cwd=self.private))
        self.assertEqual(self.git('diff', '--cached', '--name-only', cwd=self.public), '')

    def test_setup_autosaves_and_pushes_only_selected_repository(self):
        remote = self.directory / 'config.git'
        self.git('init', '--bare', '--initial-branch=main', str(remote), cwd=self.private)
        self.git('remote', 'add', 'origin', str(remote), cwd=self.private)
        self.git('push', '-u', 'origin', 'main', cwd=self.private)
        public_state = self.public_state()
        self.assert_success(self.invoke('setup', '--offline', '--hm-only', '-nc', '-nrs', '-m', 'selected update'))
        self.assertEqual(self.git('log', '-1', '--format=%B', cwd=self.private), 'selected update')
        self.assertEqual(self.git('rev-parse', 'HEAD', cwd=self.private), self.git('rev-parse', 'main', cwd=remote))
        self.assertEqual(self.public_state(), public_state)

    def test_setup_syncs_selected_upstream_and_restores_dirty_files(self):
        remote = self.directory / 'config.git'
        upstream = self.directory / 'upstream'
        self.git('init', '--bare', '--initial-branch=main', str(remote), cwd=self.private)
        self.git('remote', 'add', 'origin', str(remote), cwd=self.private)
        self.git('push', '-u', 'origin', 'main', cwd=self.private)
        self.git('clone', str(remote), str(upstream), cwd=self.directory)
        (upstream / 'upstream-change').write_text('upstream\n')
        self.git('add', '.', cwd=upstream)
        self.git('commit', '-m', 'upstream update', cwd=upstream)
        self.git('push', cwd=upstream)
        public_state = self.public_state()
        self.assert_success(self.invoke('setup', '--hm-only', '-n', '-nc', '-nrs'))
        self.assertEqual((self.private / 'upstream-change').read_text(), 'upstream\n')
        self.assertEqual((self.private / 'dirty-private').read_text(), 'private dirty\n')
        self.assertEqual(self.public_state(), public_state)
        self.assertEqual(self.git('stash', 'list', cwd=self.private), '')

    def test_verify_discovers_and_stages_only_selected_root(self):
        public_state = self.public_state()
        self.assert_success(self.invoke('verify-configs', '--no-parallel', 'fixture'))
        self.assertTrue(all(call['cwd'] == str(self.private) for call in self.calls()))
        self.assertIn('dirty-private', self.git('diff', '--cached', '--name-only', cwd=self.private))
        self.assertEqual(self.public_state(), public_state)

    def test_setup_list_uses_selected_root_without_changing_caller(self):
        self.assert_success(self.invoke('setup', '--list', '--offline'))
        self.assertEqual(self.calls()[0]['cwd'], str(self.private))
        self.assertIn('fixture', self.invoke('setup', '--list', '--offline').stdout)

    def test_switch_hm_environment_selects_checkout_and_environment(self):
        public_state = self.public_state()
        self.assert_success(self.invoke('switch-hm', '-np'))
        self.assertEqual(self.calls()[0]['cwd'], str(self.private))
        self.assertEqual(self.calls()[0]['loaded'], 'selected')
        self.assertEqual(self.public_state(), public_state)
        self.assertEqual(self.git('status', '--porcelain', cwd=self.private), '')

    def test_relative_root_is_canonical_before_bootstrap(self):
        relative = os.path.relpath(self.private, self.caller)
        self.assert_success(self.invoke('setup', '--help', overrides={
            'NIX_CONFIG_FLAKE_DIR': relative, 'NIX_CONFIG_DEV_SHELL': '',
        }))
        self.assertEqual(self.calls()[0]['cwd'], str(self.private))

    def test_full_system_routes_keep_selected_root_for_linux_darwin_and_boot(self):
        for platform, options, expected in [
            ('linux', ['-s'], 'switch-to-configuration'),
            ('linux', ['--boot'], 'boot'),
            ('darwin', ['-s'], 'darwin-rebuild'),
            ('darwin', ['--boot'], None),
        ]:
            with self.subTest(platform=platform, options=options):
                self.log.write_text('')
                boundaries = Path(self.env['TEST_BOUNDARY_LOG'])
                boundaries.write_text('')
                result = self.invoke('setup', '--offline', '-n', '-nc', '-nrs', *options, overrides={
                    'TEST_SYSTEM_META': json.dumps({'fixture': dict(platform=platform, group='fixture', owner='alice', fqn=None)}),
                })
                self.assert_success(result)
                calls = self.calls()
                self.assertTrue(all(call['cwd'] == str(self.private) for call in calls))
                target = next(arg for call in calls if 'build' in call['args'] for arg in call['args'] if '#' in arg)
                self.assertIn('darwinConfigurations' if platform == 'darwin' else 'nixosConfigurations', target)
                effects = boundaries.read_text()
                if expected:
                    self.assertIn(expected, effects)
                else:
                    self.assertEqual(effects, '')
                self.assertEqual(self.git('diff', '--cached', '--name-only', cwd=self.public), '')

    def test_remote_full_switch_uses_configured_address_from_selected_root(self):
        self.assert_success(self.invoke('setup', '--offline', '-n', '-nc', '-nrs', '-ncs', '-s', 'server', overrides={
            'TEST_SYSTEM_META': json.dumps({'server': dict(platform='linux', group='fixture', owner='alice', fqn='server.example.invalid')}),
        }))
        calls = self.calls()
        self.assertTrue(all(call['cwd'] == str(self.private) for call in calls))
        effects = Path(self.env['TEST_BOUNDARY_LOG']).read_text()
        self.assertIn('root@server.example.invalid', effects)
        self.assertIn('switch-to-configuration', effects)

    def test_legacy_switch_helpers_stage_and_commit_only_selected_repository(self):
        public_state = self.public_state()
        for helper in ('switch', 'switch-darwin'):
            with self.subTest(helper=helper):
                (self.private / 'profile.nix').write_text(helper)
                self.assert_success(self.invoke(helper))
                self.assertEqual(self.git('status', '--porcelain', cwd=self.private), '')
                self.assertEqual(self.public_state(), public_state)

    def test_edit_secret_keeps_caller_path_and_selected_environment(self):
        secret = self.caller / 'token.age'
        secret.write_text('synthetic ciphertext\n')
        (self.directory / 'age-key.age').write_text('synthetic password backup\n')
        runtime = self.directory / 'runtime-key'
        self.assert_success(self.invoke('edit-secret', 'token.age', overrides={
            'TEST_OS': 'Darwin', 'AGE_RUNTIME_KEY': str(runtime), 'NIX_CONFIG_DEV_SHELL': '',
        }))
        calls = self.calls()
        self.assertEqual(calls[0]['cwd'], str(self.private))
        effects = Path(self.env['TEST_BOUNDARY_LOG']).read_text()
        self.assertIn(str(secret), effects)
        self.assertIn('selected', effects)
        self.assertFalse(runtime.exists())
        self.assertFalse(Path(str(runtime) + '.lock').exists())

    def test_kanata_verification_uses_selected_root_for_discovery(self):
        public_state = self.public_state()
        self.assert_success(self.invoke('verify-kanata-configs', '--no-parallel', 'fixture'))
        self.assertTrue(all(call['cwd'] == str(self.private) for call in self.calls()))
        self.assertEqual(self.public_state(), public_state)

    def test_masterkey_bootstrap_uses_selected_root(self):
        self.assert_success(self.invoke('update-masterkeys', overrides={
            'NIX_CONFIG_DEV_SHELL': '', 'TEST_STOP_DEVSHELL': '1',
        }))
        self.assertEqual(self.calls()[0]['cwd'], str(self.private))
        self.assertIn('develop', self.calls()[0]['args'])


if __name__ == '__main__':
    unittest.main()
