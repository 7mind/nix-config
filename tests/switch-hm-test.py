#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


# Specified-origin Behavioral-Active Effectual-GoodCommunication tests:
# real local Git repositories/remotes; Nix activation is a command-boundary dummy.
ROOT = Path(__file__).resolve().parents[1]


class SwitchHomeManagerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        script = ROOT / "switch-hm"
        if not script.is_file() or not os.access(script, os.X_OK):
            raise AssertionError("switch-hm must exist and be executable")

    def setUp(self):
        (ROOT / "debug").mkdir(exist_ok=True)
        temporary = tempfile.TemporaryDirectory(prefix="switch-hm-test-", dir=ROOT / "debug")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.repo = self.directory / "configuration checkout"
        self.repo.mkdir()
        self.caller = self.directory / "different cwd"
        self.caller.mkdir()
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        self.log = self.directory / "nix.jsonl"
        self.ssh_log = self.directory / "ssh.jsonl"
        self.age_log = self.directory / "age.jsonl"
        self.env = os.environ | {
            "HOME": str(self.directory),
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_ALLOW_PROTOCOL": "file",
            "GIT_AUTHOR_NAME": "Fixture",
            "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
            "GIT_COMMITTER_NAME": "Fixture",
            "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
            "TEST_NIX_LOG": str(self.log),
            "TEST_SSH_LOG": str(self.ssh_log),
            "TEST_REMOTE_INFO": json.dumps([
                "alice", "server", "aarch64", "Linux", "/home/alice",
                "/nix/var/nix/profiles/default/bin/nix-store",
            ]),
            "TEST_CONFIG_USER": "alice",
            "TEST_CONFIG_HOME": "/home/alice",
            "NIX_SSHOPTS": "",
            "TEST_HOST": "workstation",
            "TEST_USER": "alice",
            "TEST_ARCH": "x86_64",
            "TEST_OS": "Linux",
            "TEST_HOME_CONFIGURATIONS": json.dumps([
                "bob@laptop-aarch64-darwin", "alice@workstation-x86_64", "alice@server-aarch64",
            ]),
            "USER": "not-the-login-user",
            "TEST_REKEY_IDENTITY": str(self.directory / "master identity"),
            "TEST_AGE_LOG": str(self.age_log),
            "AGE_RUNTIME_KEY": str(self.directory / "master identity"),
            "AGE_TPM_IDENTITY": str(self.directory / ".age" / "tpm-identity.txt"),
            "AGE_MASTER_KEY_TPM": str(self.directory / ".age" / "master-key.age"),
            "NIX_CONFIG_DEV_SHELL": "1",
            "SWITCH_HM_DEV_SHELL_REEXEC": "",
        }
        for name, body in {
            "nix": """import json, os, sys
args = sys.argv[1:]
with open(os.environ['TEST_NIX_LOG'], 'a') as log:
    log.write(json.dumps({'cwd': os.getcwd(), 'args': args}) + '\\n')
command = next(arg for arg in args if arg in ('run', 'eval', 'build', 'copy', 'develop'))
status = int(os.environ.get('TEST_NIX_' + command.upper() + '_STATUS', os.environ.get('TEST_NIX_STATUS', '0')))
if status:
    print('evaluation failed', file=sys.stderr)
    sys.exit(status)
if command == 'develop':
    import subprocess
    env = os.environ.copy()
    if 'TEST_DEVSHELL_PATH' in env:
        env['PATH'] = env['TEST_DEVSHELL_PATH']
    sys.exit(subprocess.run(args[args.index('--command') + 1:], env=env).returncode)
if command == 'run' and any('#agenix-rekey-homes.' in arg for arg in args):
    assert sys.stdin.read() == ''
    assert os.environ['AGENIX_REKEY_ADD_TO_GIT'] == 'false'
    if os.environ.get('TEST_REQUIRE_UNLOCKED_IDENTITY') == '1':
        from pathlib import Path
        identity = Path(os.environ['TEST_REKEY_IDENTITY'])
        assert identity.read_text() == 'synthetic decrypted identity\\n'
        assert identity.stat().st_mode & 0o777 == 0o600
    if 'TEST_REKEY_READY' in os.environ:
        import signal
        Path(os.environ['TEST_REKEY_READY']).write_text(str(os.getpid()))
        signal.pause()
    if os.environ.get('TEST_REKEY_SIGNAL') == '1':
        import signal
        os.kill(os.getppid(), signal.SIGTERM)
        sys.exit(0)
    status = int(os.environ.get('TEST_REKEY_STATUS', '0'))
    if status:
        sys.exit(status)
    from pathlib import Path
    output = Path(os.environ.get('TEST_REKEY_OUTPUT', 'private/secrets/rekeyed/fixture/token.age'))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text('synthetic ciphertext\\n')
if command == 'eval':
    if any(arg.endswith('.config.age') for arg in args):
        print(os.environ.get('TEST_REKEY_DIRECTORY', '/nix/store/00000000000000000000000000000000-source/private/secrets/rekeyed/fixture'))
        print(os.environ['TEST_REKEY_IDENTITY'])
    elif any(arg.endswith('.config.home') for arg in args):
        print('bob' if '--override-input' in args else os.environ['TEST_CONFIG_USER'])
        print('/home/bob' if '--override-input' in args else os.environ['TEST_CONFIG_HOME'])
    else:
        for name in sorted(json.loads(os.environ['TEST_HOME_CONFIGURATIONS'])):
            print(name)
if os.environ.get('TEST_EXPECT_KEY_ABSENT_DURING_ACTIVATION') == '1' and (command == 'build' or (command == 'run' and any('#home-manager-cli' in arg for arg in args))):
    from pathlib import Path
    assert not Path(os.environ['TEST_REKEY_IDENTITY']).exists()
if os.environ.get('TEST_REQUIRE_REKEY_STAGED') == '1' and (command == 'build' or (command == 'run' and any('#home-manager-cli' in arg for arg in args))):
    import subprocess
    subprocess.run(['git', 'ls-files', '--error-unmatch', os.environ.get('TEST_REKEY_OUTPUT', 'private/secrets/rekeyed/fixture/token.age')], check=True, stdout=subprocess.DEVNULL)
if command == 'build' and '--dry-run' not in args:
    print('/nix/store/00000000000000000000000000000000-home-manager-generation')
""",
            "ssh": """import json, os, subprocess, sys
args = sys.argv[1:]
probe = args[-2:] == ['sh', '-s']
script = sys.stdin.read() if probe else ''
with open(os.environ['TEST_SSH_LOG'], 'a') as log:
    log.write(json.dumps({'cwd': os.getcwd(), 'args': args, 'stdin': script}) + '\\n')
status = int(os.environ.get('TEST_SSH_PROBE_STATUS' if probe else 'TEST_SSH_ACTIVATE_STATUS', '0'))
if status:
    sys.exit(status)
if probe:
    if 'TEST_REMOTE_PATH' in os.environ:
        env = os.environ | {'PATH': os.environ['TEST_REMOTE_PATH']}
        result = subprocess.run([os.environ['TEST_PROBE_SHELL'], '-s'], input=script, env=env, text=True, capture_output=True)
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        sys.exit(result.returncode)
    for value in json.loads(os.environ['TEST_REMOTE_INFO']):
        print(value)
""",
            "age": """import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['TEST_AGE_LOG'], 'a') as log:
    log.write(json.dumps({'cwd': os.getcwd(), 'args': args}) + '\\n')
assert args[0] == '-d'
assert Path(args[args.index('-i') + 1]).is_file()
assert Path(args[-1]).is_file()
output = Path(args[args.index('-o') + 1])
output.write_text('synthetic decrypted identity\\n')
if os.environ.get('TEST_CREATE_COMPETING_KEY') == '1':
    Path(os.environ['TEST_REKEY_IDENTITY']).write_text('other process identity\\n')
sys.exit(int(os.environ.get('TEST_AGE_STATUS', '0')))
""",
            "age-plugin-tpm": "import sys\nsys.exit(0)\n",
            "hostname": "import os, sys\nassert sys.argv[1:] == ['-s']\nprint(os.environ['TEST_HOST'])\n",
            "id": "import os, sys\nassert sys.argv[1:] == ['-un']\nprint(os.environ['TEST_USER'])\n",
            "uname": "import os, sys\nprint(os.environ[{'-m': 'TEST_ARCH', '-s': 'TEST_OS'}[sys.argv[1]]])\n",
        }.items():
            executable = self.bin / name
            executable.write_text(f"#!{sys.executable}\n{body}")
            executable.chmod(0o755)

        shutil.copy2(ROOT / "switch-hm", self.repo / "switch-hm")
        self.remote = self.directory / "main.git"
        self.module_remote = self.directory / "module.git"
        self.module_source = self.directory / "module-source"
        self.module_source.mkdir()
        self.git("init", "--bare", "--initial-branch=main", str(self.remote))
        self.git("init", "--bare", "--initial-branch=main", str(self.module_remote))
        self.git("init", "--initial-branch=main", cwd=self.module_source)
        (self.module_source / "settings.txt").write_text("initial\n")
        self.git("add", ".", cwd=self.module_source)
        self.git("commit", "-m", "initial", cwd=self.module_source)
        self.git("remote", "add", "origin", str(self.module_remote), cwd=self.module_source)
        self.git("push", "-u", "origin", "main", cwd=self.module_source)
        self.git("init", "--initial-branch=main")
        self.git("submodule", "add", str(self.module_remote), "support")
        self.module = self.repo / "support"
        self.git("add", ".")
        self.git("commit", "-m", "initial")
        self.git("remote", "add", "origin", str(self.remote))
        self.git("push", "-u", "origin", "main")
        self.initial = self.git("rev-parse", "HEAD")
        self.module_initial = self.git("rev-parse", "HEAD", cwd=self.module)
        (self.repo / "settings.txt").write_text("updated\n")
        (self.module / "settings.txt").write_text("updated\n")

    def git(self, *args, cwd=None):
        result = subprocess.run(["git", *args], cwd=self.repo if cwd is None else cwd,
                                env=self.env, text=True, capture_output=True, check=True)
        return result.stdout.strip()

    def invoke(self, *args, overrides=None):
        env = self.env if overrides is None else self.env | overrides
        return subprocess.run([str(self.repo / "switch-hm"), *args], cwd=self.caller,
                              env=env, text=True, capture_output=True)

    def calls(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def external_checkout(self):
        # Real independent Git checkout, deliberately without a switch-hm script.
        external = self.directory / "external checkout ' $(touch should-not-exist)"
        external.mkdir()
        self.git('init', '--initial-branch=main', cwd=external)
        (external / 'flake.nix').write_text('{}\n')
        self.git('add', '.', cwd=external)
        self.git('commit', '-m', 'initial', cwd=external)
        (external / 'profile.nix').write_text('{}\n')
        return external

    # Effectual-GoodCommunication @specified: real independent Git sources with
    # recording Nix/SSH boundaries; no live activation or remote connection.
    def test_external_local_switch_selects_and_commits_only_external_checkout(self):
        external = self.external_checkout()
        source_state = self.git('status', '--porcelain')
        self.assert_success(self.invoke(f'--flake-dir={external}', '--no-push', '-m', 'external update'))
        self.assertFalse((external / 'switch-hm').exists())
        self.assertEqual(self.calls()[0]['cwd'], str(external))
        self.assertEqual(self.calls()[0]['args'][-1], '.?submodules=1#alice@workstation-x86_64')
        self.assertEqual(self.git('log', '-1', '--format=%B', cwd=external), 'external update')
        self.assertEqual(self.git('status', '--porcelain', cwd=external), '')
        self.assertEqual(self.git('status', '--porcelain'), source_state)
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.initial)
        self.assertEqual(self.git('rev-parse', 'HEAD', cwd=self.module), self.module_initial)

    def test_external_remote_switch_evaluates_builds_and_stages_external_checkout(self):
        external = self.external_checkout()
        self.assert_success(self.invoke('--flake-dir', str(external), '--target-host', 'server', '-n'))
        self.assertEqual(len(self.calls()), 3)
        self.assertTrue(all(call['cwd'] == str(external) for call in self.calls()))
        self.assertTrue(all(call['cwd'] == str(external) for call in self.ssh_calls()))
        self.assertTrue(any('homeConfigurations."alice@server-aarch64".activationPackage' in arg
                            for arg in self.calls()[1]['args']))
        self.assertIn('profile.nix', self.git('diff', '--cached', '--name-only', cwd=external))
        self.assertEqual(self.git('diff', '--cached', '--name-only'), '')
        self.assertEqual(self.git('log', '-1', '--format=%B', cwd=external), 'initial')

    def test_external_relative_directory_survives_devshell_reexec_without_script_copy(self):
        external = self.external_checkout()
        relative = os.path.relpath(external, self.caller)
        self.assert_success(self.invoke('--flake-dir', relative, '-n',
                                        overrides={'NIX_CONFIG_DEV_SHELL': ''}))
        self.assertEqual(len(self.calls()), 2)
        self.assertIn('develop', self.calls()[0]['args'])
        self.assertEqual(self.calls()[0]['cwd'], str(external))
        self.assertEqual(self.calls()[1]['cwd'], str(external))
        self.assertIn('profile.nix', self.git('diff', '--cached', '--name-only', cwd=external))
        self.assertFalse((self.caller / 'should-not-exist').exists())
        self.assertFalse((external / 'should-not-exist').exists())
        self.assertFalse((external / 'switch-hm').exists())

    def test_external_list_evaluates_without_staging_or_devshell(self):
        external = self.external_checkout()
        self.assert_success(self.invoke('--flake-dir', str(external), '--list',
                                        overrides={'NIX_CONFIG_DEV_SHELL': ''}))
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(self.calls()[0]['cwd'], str(external))
        self.assertIn('eval', self.calls()[0]['args'])
        self.assertEqual(self.git('diff', '--cached', '--name-only', cwd=external), '')
        self.assertEqual(self.git('diff', '--cached', '--name-only'), '')

    def test_external_root_rekey_stages_ciphertext_before_remote_build(self):
        external = self.external_checkout()
        Path(self.env['TEST_REKEY_IDENTITY']).write_text('synthetic identity\n')
        self.assert_success(self.invoke('--flake-dir', str(external), '--rekey',
                                        '--target-host', 'server', '-n', overrides={
            'TEST_REKEY_DIRECTORY': '/nix/store/source/secrets/rekeyed/fixture',
            'TEST_REKEY_OUTPUT': 'secrets/rekeyed/fixture/token.age',
            'TEST_REQUIRE_REKEY_STAGED': '1',
        }))
        self.assertEqual(len(self.calls()), 5)
        self.assertTrue(all(call['cwd'] == str(external) for call in self.calls()))
        self.assertIn('secrets/rekeyed/fixture/token.age',
                      self.git('diff', '--cached', '--name-only', cwd=external))
        self.assertEqual(self.git('diff', '--cached', '--name-only'), '')
        self.assertEqual(self.git('log', '-1', '--format=%B', cwd=external), 'initial')

    def test_external_private_submodule_rekey_stages_in_own_git_repo(self):
        external = self.external_checkout()
        self.git('submodule', 'add', str(self.module_remote), 'private', cwd=external)
        self.git('commit', '-am', 'add private fixture', cwd=external)
        Path(self.env['TEST_REKEY_IDENTITY']).write_text('synthetic identity\n')
        self.assert_success(self.invoke('--flake-dir', str(external), '--rekey', '-n'))
        self.assertIn('secrets/rekeyed/fixture/token.age',
                      self.git('diff', '--cached', '--name-only', cwd=external / 'private'))
        self.assertEqual(self.git('diff', '--cached', '--name-only'), '')

    def test_external_rekey_rejects_runtime_identity_inside_selected_checkout(self):
        external = self.external_checkout()
        self.enroll_tpm_fixture()
        identity = external / 'runtime key'
        result = self.invoke('--flake-dir', str(external), '--rekey', '-n', overrides={
            'TEST_REKEY_IDENTITY': str(identity), 'AGE_RUNTIME_KEY': str(identity),
            'TEST_REKEY_DIRECTORY': '/nix/store/source/secrets/rekeyed/fixture',
        })
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('outside the checkout', result.stderr)
        self.assertFalse(identity.exists())
        self.assertEqual(self.age_calls(), [])
        self.assertEqual(len(self.calls()), 1)

    def test_defaults_from_different_cwd_commit_and_push_without_identifiers(self):
        self.assert_success(self.invoke())
        self.assertEqual(self.calls(), [{"cwd": str(self.repo), "args": [
            "--extra-experimental-features", "nix-command flakes", "run",
            ".?submodules=1#home-manager-cli", "--", "switch", "-b", "hmbak",
            "--flake", ".?submodules=1#alice@workstation-x86_64",
        ]}])
        for repo in [self.repo, self.module]:
            self.assertEqual(self.git("log", "-1", "--format=%B", cwd=repo), "autosave")
            self.assertEqual(self.git("status", "--porcelain", cwd=repo), "")
        self.assertEqual(self.git("rev-parse", "HEAD"), self.git("rev-parse", "main", cwd=self.remote))
        self.assertEqual(self.git("rev-parse", "HEAD", cwd=self.module),
                         self.git("rev-parse", "main", cwd=self.module_remote))
        head = self.git("rev-parse", "HEAD")
        self.assert_success(self.invoke())
        self.assertEqual(self.git("rev-parse", "HEAD"), head)

    def test_no_git_skips_commits_and_push_but_stages_for_flake_visibility(self):
        self.assert_success(self.invoke("-n", "another-host", "--user", "bob", "--", "--show-trace"))
        self.assertEqual(self.calls()[0]["args"][-3:], ["--show-trace", "--flake", ".?submodules=1#bob@another-host-x86_64"])
        self.assertEqual(self.git("rev-parse", "HEAD"), self.initial)
        self.assertEqual(self.git("rev-parse", "HEAD", cwd=self.module), self.module_initial)
        self.assertIn("settings.txt", self.git("diff", "--cached", "--name-only"))
        self.assertIn("settings.txt", self.git("diff", "--cached", "--name-only", cwd=self.module))

    def test_no_push_commits_locally_with_safe_custom_message(self):
        message = 'local update "quoted"; $(touch should-not-exist)'
        self.assert_success(self.invoke("--no-push", f"--message={message}"))
        for repo in [self.repo, self.module]:
            self.assertEqual(self.git("log", "-1", "--format=%B", cwd=repo), message)
            self.assertFalse((repo / "should-not-exist").exists())
        self.assertEqual(self.git("rev-parse", "main", cwd=self.remote), self.initial)
        self.assertEqual(self.git("rev-parse", "main", cwd=self.module_remote), self.module_initial)

    def test_platform_suffixes_match_home_configuration_naming(self):
        for platform, architecture, suffix in [
            ("Linux", "aarch64", "aarch64"),
            ("Darwin", "arm64", "aarch64-darwin"),
            ("Darwin", "x86_64", "x86_64-darwin"),
        ]:
            with self.subTest(platform=platform, architecture=architecture):
                self.assert_success(self.invoke("--no-git", overrides={"TEST_OS": platform, "TEST_ARCH": architecture}))
                self.assertEqual(self.calls()[-1]["args"][-1], f".?submodules=1#alice@workstation-{suffix}")

    def test_switch_failure_does_not_commit_or_push(self):
        result = self.invoke(overrides={"TEST_NIX_STATUS": "17"})
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertEqual(self.git("rev-parse", "HEAD"), self.initial)
        self.assertEqual(self.git("rev-parse", "HEAD", cwd=self.module), self.module_initial)
        self.assertEqual(self.git("rev-parse", "main", cwd=self.remote), self.initial)

    def test_commit_failure_is_not_silently_ignored(self):
        hook = Path(self.git("rev-parse", "--path-format=absolute", "--git-path", "hooks/pre-commit", cwd=self.module))
        hook.write_text(f"#!{shutil.which('bash')}\nexit 19\n")
        hook.chmod(0o755)
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git("rev-parse", "HEAD"), self.initial)
        self.assertEqual(self.git("rev-parse", "main", cwd=self.remote), self.initial)

    def test_list_configurations_from_different_cwd_without_git_changes(self):
        self.git("add", "settings.txt", cwd=self.module)
        states = {repo: self.git("status", "--porcelain", cwd=repo)
                  for repo in [self.repo, self.module]}
        for option in ["--list", "-l"]:
            with self.subTest(option=option):
                result = self.invoke(option, overrides={"TEST_OS": "Unsupported"})
                self.assert_success(result)
                self.assertEqual(result.stdout.splitlines(), [
                    "alice@server-aarch64", "alice@workstation-x86_64", "bob@laptop-aarch64-darwin",
                ])
                call = self.calls()[-1]
                self.assertEqual(call["cwd"], str(self.repo))
                self.assertEqual(call["args"][:3], [
                    "--extra-experimental-features", "nix-command flakes", "eval",
                ])
                self.assertIn(".?submodules=1#homeConfigurations", call["args"])
                self.assertIn("--raw", call["args"])
                self.assertIn("--apply", call["args"])
                self.assertIn("--no-write-lock-file", call["args"])
        self.assertEqual(len(self.calls()), 2)
        for repo, state in states.items():
            self.assertEqual(self.git("status", "--porcelain", cwd=repo), state)
        self.assertEqual(self.git("rev-parse", "HEAD"), self.initial)
        self.assertEqual(self.git("rev-parse", "HEAD", cwd=self.module), self.module_initial)
        self.assertEqual(self.git("rev-parse", "main", cwd=self.remote), self.initial)
        self.assertEqual(self.git("rev-parse", "main", cwd=self.module_remote), self.module_initial)

    def test_list_empty_configurations(self):
        result = self.invoke("--list", overrides={"TEST_HOME_CONFIGURATIONS": "[]"})
        self.assert_success(result)
        self.assertEqual(result.stdout, "")

    def test_list_failure_propagates_without_git_changes(self):
        result = self.invoke("--list", overrides={"TEST_NIX_STATUS": "17"})
        self.assertEqual(result.returncode, 17, result.stdout + result.stderr)
        self.assertIn("evaluation failed", result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(len(self.calls()), 1)
        for repo, initial in [(self.repo, self.initial), (self.module, self.module_initial)]:
            self.assertEqual(self.git("diff", "--cached", "--name-only", cwd=repo), "")
            self.assertEqual(self.git("rev-parse", "HEAD", cwd=repo), initial)

    def test_help_and_invalid_arguments_have_no_side_effects(self):
        result = self.invoke("--help")
        self.assert_success(result)
        self.assertIn("-l, --list", result.stdout)
        for args in [("--unknown",), ("--user",), ("--message",), ("--message=",),
                     ("first", "second"), ("bad#host",), ("--user=",),
                     ("--flake-dir",), ("--flake-dir=",), ("--flake-dir", "--list"),
                     ("--flake-dir", str(self.directory / "missing checkout"))]:
            with self.subTest(args=args):
                self.assertNotEqual(self.invoke(*args).returncode, 0)
        self.assertEqual(self.calls(), [])
        self.assertEqual(self.git("diff", "--cached", "--name-only"), "")

    def ssh_calls(self):
        if not self.ssh_log.exists():
            return []
        return [json.loads(line) for line in self.ssh_log.read_text().splitlines()]

    def test_remote_switch_builds_copies_and_activates_with_remote_identity(self):
        self.assert_success(self.invoke("--target-host", "alice@server", "--no-push",
                                        overrides={"TEST_OS": "Unsupported"}))
        calls = self.calls()
        self.assertEqual(len(calls), 3)
        self.assertTrue(any(arg.endswith('homeConfigurations."alice@server-aarch64".config.home')
                            for arg in calls[0]["args"]))
        self.assertIn('homeConfigurations."alice@server-aarch64".activationPackage',
                      calls[1]["args"][-1].split("#")[1])
        self.assertIn("--no-link", calls[1]["args"])
        self.assertIn("--print-out-paths", calls[1]["args"])
        destination = calls[2]["args"][calls[2]["args"].index("--to") + 1]
        self.assertTrue(destination.startswith("ssh://alice@server"))
        ssh = self.ssh_calls()
        self.assertEqual(len(ssh), 2)
        self.assertIn("alice@server", ssh[0]["args"])
        self.assertIn("HOME_MANAGER_BACKUP_EXT=hmbak", ssh[1]["args"][-1])
        self.assertNotIn("sudo", ssh[1]["args"][-1])
        self.assertTrue(ssh[1]["args"][-1].endswith("/activate'"))
        self.assertEqual(self.git("log", "-1", "--format=%B"), "autosave")
        self.assertEqual(self.git("rev-parse", "main", cwd=self.remote), self.initial)

    def test_remote_nix_profile_is_found_without_nix_on_ssh_path(self):
        store = self.directory / '.nix-profile' / 'bin' / 'nix-store'
        store.parent.mkdir(parents=True)
        store.write_text('#!/bin/sh\nexit 0\n')
        store.chmod(0o755)
        result = self.invoke('--target-host', 'server', '-n', overrides={
            'TEST_REMOTE_PATH': f'{self.bin}:/usr/bin:/bin',
            'TEST_PROBE_SHELL': shutil.which('sh'),
            'TEST_CONFIG_HOME': str(self.directory),
        })
        self.assert_success(result)
        self.assertIn('Nix is not on the SSH PATH; using', result.stderr)
        from urllib.parse import parse_qs, urlsplit
        import shlex
        args = self.calls()[2]['args']
        destination = args[args.index('--to') + 1]
        self.assertEqual(shlex.split(parse_qs(urlsplit(destination).query)['remote-program'][0]), [str(store)])

    def test_remote_override_and_darwin_suffix(self):
        info = ["alice", "server", "arm64", "Darwin", "/home/alice",
                "/nix/var/nix/profiles/default/bin/nix-store"]
        self.assert_success(self.invoke("--target-host=server-alias", "declared-host", "--user=alice", "-n",
                                        overrides={"TEST_REMOTE_INFO": json.dumps(info)}))
        self.assertIn('homeConfigurations."alice@declared-host-aarch64-darwin".activationPackage',
                      self.calls()[1]["args"][-1])
        self.assertEqual(self.git("rev-parse", "HEAD"), self.initial)

    def test_remote_sudo_is_only_used_for_store_import(self):
        from urllib.parse import parse_qs, urlsplit
        info = ["alice", "server", "aarch64", "Linux", "/home/alice",
                "/home/alice/nix tools/it's-nix-store"]
        self.assert_success(self.invoke("--target-host", "server", "--use-remote-sudo", "-n",
                                        overrides={"TEST_REMOTE_INFO": json.dumps(info)}))
        args = self.calls()[2]["args"]
        destination = args[args.index("--to") + 1]
        program = parse_qs(urlsplit(destination).query)["remote-program"][0]
        import shlex
        self.assertEqual(shlex.split(program), ["sudo", "-n", info[-1]])
        self.assertNotIn("sudo", self.ssh_calls()[1]["args"][-1])

    def test_remote_identity_and_home_mismatch_refuse_copy_and_activation(self):
        for overrides in [{"TEST_CONFIG_USER": "bob"}, {"TEST_CONFIG_HOME": "/home/bob"}]:
            with self.subTest(overrides=overrides):
                self.log.unlink(missing_ok=True)
                self.ssh_log.unlink(missing_ok=True)
                result = self.invoke("--target-host", "server", overrides=overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("does not match", result.stderr)
                self.assertEqual(len(self.calls()), 1)
                self.assertEqual(len(self.ssh_calls()), 1)
                self.assertEqual(self.git("rev-parse", "HEAD"), self.initial)

    def test_remote_evaluation_options_apply_to_identity_validation(self):
        result = self.invoke('--target-host', 'server', '--',
                             '--override-input', 'identity', 'path:/other-profile')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('does not match', result.stderr)
        self.assertIn('--override-input', self.calls()[0]['args'])
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(len(self.ssh_calls()), 1)
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.initial)

    def test_remote_failures_never_commit_or_push(self):
        for variable in ["TEST_SSH_PROBE_STATUS", "TEST_NIX_EVAL_STATUS", "TEST_NIX_BUILD_STATUS",
                         "TEST_NIX_COPY_STATUS", "TEST_SSH_ACTIVATE_STATUS"]:
            with self.subTest(variable=variable):
                self.log.unlink(missing_ok=True)
                self.ssh_log.unlink(missing_ok=True)
                result = self.invoke("--target-host", "server", overrides={variable: "23"})
                self.assertEqual(result.returncode, 23, result.stdout + result.stderr)
                self.assertEqual(self.git("rev-parse", "HEAD"), self.initial)
                self.assertEqual(self.git("rev-parse", "HEAD", cwd=self.module), self.module_initial)
                self.assertEqual(self.git("rev-parse", "main", cwd=self.remote), self.initial)
                self.assertEqual(self.git("rev-parse", "main", cwd=self.module_remote), self.module_initial)

    # Effectual-GoodCommunication @specified: local previews stage real Git
    # sources, but Nix/SSH/age remain recording boundaries with no activation.
    def test_local_switch_keeps_selected_flake_after_passthrough_and_preserves_option_values(self):
        external = self.external_checkout()
        selected = '.?submodules=1#alice@workstation-x86_64'
        for extra in [('--flake', 'path:/unrelated#other'), ('--argstr', 'name', '--flake')]:
            with self.subTest(extra=extra):
                self.log.unlink(missing_ok=True)
                self.assert_success(self.invoke('--flake-dir', str(external), '-n', '--', *extra))
                self.assertEqual(len(self.calls()), 1)
                self.assertEqual(self.calls()[0]['cwd'], str(external))
                args = self.calls()[0]['args']
                hm_args = args[args.index('--') + 1:]
                last_flake = max(index for index, value in enumerate(hm_args) if value == '--flake')
                self.assertEqual(hm_args[last_flake + 1:], [selected])
                self.assertEqual(hm_args, ['switch', '-b', 'hmbak', *extra, '--flake', selected])
                self.assertEqual(self.ssh_calls(), [])
                self.assertEqual(self.git('log', '-1', '--format=%s', cwd=external), 'initial')

    def test_local_dry_run_uses_login_identity_stages_and_never_commits_or_pushes(self):
        self.assert_success(self.invoke('--dry-run', '--', '--show-trace'))
        self.assertEqual(self.calls(), [{'cwd': str(self.repo), 'args': [
            '--extra-experimental-features', 'nix-command flakes', 'build',
            '--dry-run', '--no-link',
            '.?submodules=1#homeConfigurations."alice@workstation-x86_64".activationPackage',
            '--show-trace',
        ]}])
        self.assertEqual(self.ssh_calls(), [])
        self.assertEqual(self.age_calls(), [])
        for repo, origin, initial in [(self.repo, self.remote, self.initial),
                                      (self.module, self.module_remote, self.module_initial)]:
            self.assertIn('settings.txt', self.git('diff', '--cached', '--name-only', cwd=repo))
            self.assertEqual(self.git('rev-parse', 'HEAD', cwd=repo), initial)
            self.assertEqual(self.git('rev-parse', 'main', cwd=origin), initial)

    def test_local_dry_run_selects_darwin_arm_configuration(self):
        self.assert_success(self.invoke('--dry-run', overrides={'TEST_OS': 'Darwin', 'TEST_ARCH': 'arm64'}))
        self.assertEqual(self.calls()[0]['args'][-1],
                         '.?submodules=1#homeConfigurations."alice@workstation-aarch64-darwin".activationPackage')
        self.assertEqual(self.ssh_calls(), [])
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.initial)

    def test_local_dry_run_uses_external_flake_and_explicit_identity_without_ssh(self):
        external = self.external_checkout()
        self.assert_success(self.invoke('--flake-dir', str(external), '--dry-run',
                                        '--user', 'bob', 'declared-host'))
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(self.calls()[0]['cwd'], str(external))
        self.assertEqual(self.calls()[0]['args'][-1],
                         '.?submodules=1#homeConfigurations."bob@declared-host-x86_64".activationPackage')
        self.assertIn('profile.nix', self.git('diff', '--cached', '--name-only', cwd=external))
        self.assertEqual(self.git('diff', '--cached', '--name-only'), '')
        self.assertEqual(self.git('log', '-1', '--format=%s', cwd=external), 'initial')
        self.assertEqual(self.ssh_calls(), [])

    def test_local_dry_run_ignores_rekey_even_when_tools_and_identity_are_missing(self):
        external = self.external_checkout()
        (self.bin / 'age').unlink()
        (self.bin / 'age-plugin-tpm').unlink()
        for command in ['bash', 'dirname', 'env', 'git', 'basename', 'sed', 'cat', 'sh']:
            (self.bin / command).symlink_to(shutil.which(command))
        self.assert_success(self.invoke('--flake-dir', str(external), '--dry-run', '--rekey', overrides={
            'PATH': str(self.bin), 'SWITCH_HM_DEV_SHELL_REEXEC': '1',
        }))
        self.assertEqual(len(self.calls()), 1)
        self.assertIn('build', self.calls()[0]['args'])
        self.assertEqual(self.age_calls(), [])
        self.assertEqual(self.ssh_calls(), [])
        self.assertFalse(Path(self.env['AGE_RUNTIME_KEY']).exists())
        self.assertFalse(Path(self.env['AGE_RUNTIME_KEY'] + '.lock').exists())
        self.assertEqual(self.git('log', '-1', '--format=%s', cwd=external), 'initial')

    def test_local_dry_run_bootstraps_only_ordinary_shell_not_rekey_arguments(self):
        self.assert_success(self.invoke('--dry-run', '--rekey', '--', '--show-trace',
                                        overrides={'NIX_CONFIG_DEV_SHELL': ''}))
        calls = self.calls()
        self.assertEqual(len(calls), 2)
        self.assertIn('develop', calls[0]['args'])
        self.assertNotIn('--show-trace', calls[0]['args'][:calls[0]['args'].index('--command')])
        self.assertIn('build', calls[1]['args'])
        self.assertIn('--show-trace', calls[1]['args'])
        self.assertEqual(self.age_calls(), [])
        self.assertEqual(self.ssh_calls(), [])
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.initial)

    def test_local_dry_run_build_failure_propagates_without_activation_or_commit(self):
        result = self.invoke('--dry-run', overrides={'TEST_NIX_BUILD_STATUS': '31'})
        self.assertEqual(result.returncode, 31, result.stdout + result.stderr)
        self.assertEqual(len(self.calls()), 1)
        self.assertIn('build', self.calls()[0]['args'])
        self.assertEqual(self.ssh_calls(), [])
        self.assertEqual(self.age_calls(), [])
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.initial)
        self.assertEqual(self.git('rev-parse', 'HEAD', cwd=self.module), self.module_initial)
        self.assertEqual(self.git('rev-parse', 'main', cwd=self.remote), self.initial)

    def test_remote_dry_run_does_not_copy_activate_commit_or_push(self):
        self.assert_success(self.invoke("--target-host", "server", "--dry-run", "--", "--show-trace"))
        self.assertEqual(len(self.calls()), 2)
        self.assertIn("--dry-run", self.calls()[1]["args"])
        self.assertIn("--show-trace", self.calls()[1]["args"])
        self.assertEqual(len(self.ssh_calls()), 1)
        self.assertEqual(self.git("rev-parse", "HEAD"), self.initial)
        self.assertEqual(self.git("rev-parse", "main", cwd=self.remote), self.initial)

    def test_remote_ssh_options_reach_probe_and_copy(self):
        self.assert_success(self.invoke("--target-host", "server", "-n",
                                        overrides={"NIX_SSHOPTS": "-F fixture-config -p 2222"}))
        for call in self.ssh_calls():
            self.assertIn("fixture-config", call["args"])
            self.assertIn("2222", call["args"])

    def test_remote_ssh_options_reject_ambiguous_whitespace_before_connecting(self):
        for value in ['-p\n2222', '-p\r2222', '-p\r\n2222']:
            with self.subTest(value=value):
                result = self.invoke('--target-host', 'server', overrides={'NIX_SSHOPTS': value})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('NIX_SSHOPTS', result.stderr)
                self.assertEqual(self.ssh_calls(), [])
                self.assertEqual(self.calls(), [])
                self.assertEqual(self.git('diff', '--cached', '--name-only'), '')

    def test_invalid_remote_options_and_metadata_do_not_stage(self):
        for args in [("--target-host",), ("--target-host=",), ("--target-host", "bad#host"),
                     ("--use-remote-sudo",), ("--dry-run", "--use-remote-sudo"), ("--target-host", "server", "--list")]:
            with self.subTest(args=args):
                self.assertNotEqual(self.invoke(*args).returncode, 0)
        for info in [["unexpected output"], ["alice", "server", "aarch64", "Unsupported", "/home/alice", "/bin/nix-store"]]:
            with self.subTest(info=info):
                self.assertNotEqual(self.invoke("--target-host", "server",
                                               overrides={"TEST_REMOTE_INFO": json.dumps(info)}).returncode, 0)
        self.assertEqual(self.git("diff", "--cached", "--name-only"), "")
        self.assertEqual(self.calls(), [])

    def test_rekey_outside_dev_shell_bootstraps_checkout_shell_once(self):
        self.enroll_tpm_fixture()
        result = self.invoke('--rekey', '-n', '--', '--override-input', 'ponygirls', 'path:/updated-input',
                             overrides={'NIX_CONFIG_DEV_SHELL': ''})
        self.assert_success(result)
        calls = self.calls()
        self.assertEqual(len(calls), 4)
        self.assertIn('develop', calls[0]['args'])
        self.assertIn('.?submodules=1', calls[0]['args'])
        self.assertIn('--no-write-lock-file', calls[0]['args'])
        self.assertIn('NIX_CONFIG_DEV_SHELL=1', calls[0]['args'])
        self.assertEqual(calls[0]['cwd'], str(self.repo))
        for call in calls:
            self.assertIn('--override-input', call['args'])
        self.assertEqual(len(self.age_calls()), 1)
        self.assert_unlock_artifacts_removed()

    def test_normal_switch_outside_dev_shell_also_bootstraps(self):
        self.assert_success(self.invoke('-n', overrides={'NIX_CONFIG_DEV_SHELL': ''}))
        self.assertEqual(len(self.calls()), 2)
        self.assertIn('develop', self.calls()[0]['args'])
        self.assertIn('#home-manager-cli', ' '.join(self.calls()[1]['args']))

    def test_dev_shell_failure_does_not_stage_or_unlock(self):
        self.enroll_tpm_fixture()
        result = self.invoke('--rekey', overrides={
            'NIX_CONFIG_DEV_SHELL': '', 'TEST_NIX_DEVELOP_STATUS': '47',
        })
        self.assertEqual(result.returncode, 47, result.stderr)
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(self.age_calls(), [])
        self.assertEqual(self.git('diff', '--cached', '--name-only'), '')
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.initial)

    def test_stale_shell_missing_age_refreshes_before_rekey(self):
        self.enroll_tpm_fixture()
        shell_bin = self.directory / 'fresh shell bin'
        shell_bin.mkdir()
        (self.bin / 'age').rename(shell_bin / 'age')
        for command in ['bash', 'dirname', 'env']:
            (self.bin / command).symlink_to(shutil.which(command))
        result = self.invoke('--rekey', '-n', overrides={
            'PATH': str(self.bin),
            'TEST_DEVSHELL_PATH': f'{shell_bin}:{self.env["PATH"]}',
        })
        self.assert_success(result)
        self.assertIn('develop', self.calls()[0]['args'])
        self.assertEqual(len(self.calls()), 4)
        self.assertEqual(len(self.age_calls()), 1)
        self.assert_unlock_artifacts_removed()

    def test_failed_shell_refresh_does_not_reexec_indefinitely(self):
        (self.bin / 'age').unlink()
        for command in ['bash', 'dirname', 'env']:
            (self.bin / command).symlink_to(shutil.which(command))
        result = self.invoke('--rekey', '-n', overrides={'PATH': str(self.bin)})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('development shell still lacks required rekey tools', result.stderr)
        self.assertEqual(len(self.calls()), 1)
        self.assertIn('develop', self.calls()[0]['args'])
        self.assertEqual(self.age_calls(), [])

    def test_list_without_dev_shell_does_not_bootstrap(self):
        self.assert_success(self.invoke('--list', overrides={'NIX_CONFIG_DEV_SHELL': ''}))
        self.assertEqual(len(self.calls()), 1)
        self.assertIn('eval', self.calls()[0]['args'])
        self.assertEqual(self.git('diff', '--cached', '--name-only'), '')

    def enroll_tpm_fixture(self):
        for variable in ['AGE_TPM_IDENTITY', 'AGE_MASTER_KEY_TPM']:
            path = Path(self.env[variable])
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('synthetic enrolled TPM fixture\n')

    def age_calls(self):
        if not self.age_log.exists():
            return []
        return [json.loads(line) for line in self.age_log.read_text().splitlines()]

    def assert_unlock_artifacts_removed(self):
        identity = Path(self.env['TEST_REKEY_IDENTITY'])
        self.assertFalse(identity.exists())
        self.assertEqual(list(identity.parent.glob(identity.name + '.unlock.*')), [])

    def test_rekey_unlocks_existing_tpm_enrollment_and_cleans_before_activation(self):
        self.enroll_tpm_fixture()
        result = self.invoke('--rekey', '-n', overrides={
            'TEST_REQUIRE_UNLOCKED_IDENTITY': '1',
            'TEST_EXPECT_KEY_ABSENT_DURING_ACTIVATION': '1',
        })
        self.assert_success(result)
        self.assertEqual(len(self.age_calls()), 1)
        args = self.age_calls()[0]['args']
        self.assertEqual(args[args.index('-i') + 1], self.env['AGE_TPM_IDENTITY'])
        self.assertEqual(args[-1], self.env['AGE_MASTER_KEY_TPM'])
        self.assertEqual(self.age_calls()[0]['cwd'], str(self.repo))
        self.assert_unlock_artifacts_removed()
        self.assertEqual(len(self.calls()), 3)
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.initial)

    def test_tpm_unlock_failure_removes_partial_key_and_aborts_switch(self):
        self.enroll_tpm_fixture()
        result = self.invoke('--rekey', overrides={'TEST_AGE_STATUS': '51'})
        self.assertEqual(result.returncode, 51, result.stderr)
        self.assert_unlock_artifacts_removed()
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.initial)
        self.assertEqual(self.git('rev-parse', 'main', cwd=self.remote), self.initial)

    def test_tpm_unlocked_key_is_removed_on_rekey_failure(self):
        self.enroll_tpm_fixture()
        result = self.invoke('--rekey', overrides={'TEST_REKEY_STATUS': '23'})
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual(len(self.age_calls()), 1)
        self.assert_unlock_artifacts_removed()
        self.assertEqual(len(self.calls()), 2)

    def test_tpm_unlocked_key_is_removed_on_termination(self):
        self.enroll_tpm_fixture()
        result = self.invoke('--rekey', '-n', overrides={'TEST_REKEY_SIGNAL': '1'})
        self.assertEqual(result.returncode, 143, result.stderr)
        self.assert_unlock_artifacts_removed()
        self.assertEqual(len(self.calls()), 2)

    def test_shell_only_termination_cancels_rekey_and_removes_runtime_key(self):
        import signal
        import time
        self.enroll_tpm_fixture()
        ready = self.directory / 'rekey ready'
        env = self.env | {'TEST_REKEY_READY': str(ready), 'TEST_REQUIRE_UNLOCKED_IDENTITY': '1'}
        process = subprocess.Popen([str(self.repo / 'switch-hm'), '--rekey', '-n'],
                                   cwd=self.caller, env=env, text=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   start_new_session=True)
        try:
            deadline = time.monotonic() + 5
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(ready.exists(), 'rekey child did not become ready')
            process.send_signal(signal.SIGTERM)
            process.wait(timeout=5)
            self.assert_unlock_artifacts_removed()
            self.assertEqual(process.returncode, 143)
        finally:
            if ready.exists():
                try:
                    os.killpg(int(ready.read_text()), signal.SIGKILL)
                except ProcessLookupError:
                    pass
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate(timeout=5)

    def test_concurrent_switch_cannot_reuse_another_switch_temporary_key(self):
        import signal
        import time
        self.enroll_tpm_fixture()
        ready = self.directory / 'rekey ready'
        process = subprocess.Popen([str(self.repo / 'switch-hm'), '--rekey', '-n'],
                                   cwd=self.caller, env=self.env | {'TEST_REKEY_READY': str(ready),
                                   'TEST_REQUIRE_UNLOCKED_IDENTITY': '1'}, text=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   start_new_session=True)
        try:
            deadline = time.monotonic() + 5
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(ready.exists(), 'rekey child did not become ready')
            result = self.invoke('--rekey', '-n')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('already in use by another switch', result.stderr)
            self.assertEqual(len(self.age_calls()), 1)
            process.send_signal(signal.SIGTERM)
            process.wait(timeout=5)
            self.assert_unlock_artifacts_removed()
            self.assert_success(self.invoke('--rekey', '-n'))
            self.assertEqual(len(self.age_calls()), 2)
            self.assert_unlock_artifacts_removed()
        finally:
            if ready.exists():
                try:
                    os.killpg(int(ready.read_text()), signal.SIGKILL)
                except ProcessLookupError:
                    pass
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate(timeout=5)

    def test_existing_master_identity_is_reused_without_unlock_or_cleanup(self):
        self.enroll_tpm_fixture()
        identity = Path(self.env['TEST_REKEY_IDENTITY'])
        identity.write_text('existing identity\n')
        result = self.invoke('--rekey', '-n')
        self.assert_success(result)
        self.assertEqual(self.age_calls(), [])
        self.assertEqual(identity.read_text(), 'existing identity\n')

    def test_tpm_unlock_does_not_overwrite_or_remove_a_competing_key(self):
        self.enroll_tpm_fixture()
        result = self.invoke('--rekey', '-n', overrides={'TEST_CREATE_COMPETING_KEY': '1'})
        self.assertNotEqual(result.returncode, 0)
        identity = Path(self.env['TEST_REKEY_IDENTITY'])
        self.assertEqual(identity.read_text(), 'other process identity\n')
        self.assertEqual(list(identity.parent.glob(identity.name + '.unlock.*')), [])
        self.assertEqual(len(self.calls()), 1)

    def test_enrolled_tpm_does_not_unlock_for_normal_switch_or_dry_run(self):
        self.enroll_tpm_fixture()
        self.assert_success(self.invoke('-n'))
        self.assert_success(self.invoke('--target-host', 'server', '--rekey', '--dry-run'))
        self.assertEqual(self.age_calls(), [])
        self.assert_unlock_artifacts_removed()

    def test_remote_rekey_unlocks_on_local_machine_and_cleans_before_build(self):
        self.enroll_tpm_fixture()
        result = self.invoke('--target-host', 'server', '--rekey', '-n', overrides={
            'TEST_REQUIRE_UNLOCKED_IDENTITY': '1',
            'TEST_EXPECT_KEY_ABSENT_DURING_ACTIVATION': '1',
        })
        self.assert_success(result)
        self.assertEqual(self.age_calls()[0]['cwd'], str(self.repo))
        self.assert_unlock_artifacts_removed()
        self.assertEqual(len(self.calls()), 5)
        self.assertEqual(len(self.ssh_calls()), 2)

    def test_tpm_unlock_rejects_arbitrary_configured_identity_paths(self):
        self.enroll_tpm_fixture()
        other_identity = self.directory / 'unrelated identity'
        result = self.invoke('--rekey', '-n', overrides={'TEST_REKEY_IDENTITY': str(other_identity)})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.age_calls(), [])
        self.assertFalse(other_identity.exists())
        self.assertEqual(len(self.calls()), 1)

    def test_tpm_unlock_does_not_write_plaintext_into_the_checkout(self):
        self.enroll_tpm_fixture()
        identity = self.repo / 'private' / 'secrets' / 'rekeyed' / 'fixture' / 'runtime key'
        identity.parent.mkdir(parents=True)
        result = self.invoke('--rekey', '-n', overrides={
            'TEST_REKEY_IDENTITY': str(identity),
            'AGE_RUNTIME_KEY': str(identity),
        })
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('outside the checkout', result.stderr)
        self.assertEqual(self.age_calls(), [])
        self.assertFalse(identity.exists())

    def test_rekey_before_local_switch_stages_ciphertext_and_forwards_inputs(self):
        Path(self.env['TEST_REKEY_IDENTITY']).write_text('synthetic identity\n')
        result = self.invoke('--rekey', '-n', '--', '--override-input', 'ponygirls', 'path:/updated-input',
                             overrides={'TEST_REQUIRE_REKEY_STAGED': '1'})
        self.assert_success(result)
        calls = self.calls()
        self.assertEqual(len(calls), 3)
        self.assertTrue(any(arg.endswith('.config.age') for arg in calls[0]['args']))
        self.assertIn('.?submodules=1#agenix-rekey-homes."alice@workstation-x86_64".x86_64-linux.rekey', calls[1]['args'])
        self.assertIn('home-manager-cli', ' '.join(calls[2]['args']))
        for call in calls:
            self.assertIn('--override-input', call['args'])
            self.assertIn('path:/updated-input', call['args'])
        self.assertIn('private/secrets/rekeyed/fixture/token.age', self.git('diff', '--cached', '--name-only'))
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.initial)

    def test_missing_master_identity_stops_before_rekey_and_activation(self):
        result = self.invoke('--rekey', '-n')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('master identity is not readable', result.stderr)
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.initial)

    def test_rekey_failure_stops_before_activation_commit_and_push(self):
        Path(self.env['TEST_REKEY_IDENTITY']).write_text('synthetic identity\n')
        result = self.invoke('--rekey', overrides={'TEST_REKEY_STATUS': '23'})
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual(len(self.calls()), 2)
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.initial)
        self.assertEqual(self.git('rev-parse', 'main', cwd=self.remote), self.initial)

    def test_remote_rekey_runs_locally_after_identity_validation_before_build(self):
        Path(self.env['TEST_REKEY_IDENTITY']).write_text('synthetic identity\n')
        result = self.invoke('--target-host', 'server', '--rekey', '-n',
                             overrides={'TEST_REQUIRE_REKEY_STAGED': '1'})
        self.assert_success(result)
        calls = self.calls()
        self.assertEqual(len(calls), 5)
        self.assertTrue(any(arg.endswith('.config.home') for arg in calls[0]['args']))
        self.assertTrue(any(arg.endswith('.config.age') for arg in calls[1]['args']))
        self.assertIn('.?submodules=1#agenix-rekey-homes."alice@server-aarch64".x86_64-linux.rekey', calls[2]['args'])
        self.assertIn('build', calls[3]['args'])
        self.assertIn('copy', calls[4]['args'])
        self.assertTrue(all(call['cwd'] == str(self.repo) for call in calls))

    def test_remote_dry_run_does_not_rekey_or_require_master_identity(self):
        result = self.invoke('--target-host', 'server', '--dry-run', '--rekey')
        self.assert_success(result)
        self.assertIn('not rekeying', result.stderr)
        self.assertEqual(len(self.calls()), 2)
        self.assertFalse(any('#agenix-rekey-homes.' in arg for call in self.calls() for arg in call['args']))

    def test_rekey_rejects_unscoped_storage_before_running_app(self):
        Path(self.env['TEST_REKEY_IDENTITY']).write_text('synthetic identity\n')
        for directory in ['/elsewhere/secrets',
                          '/nix/store/source/private/secrets/rekeyed',
                          '/nix/store/source/private/secrets/rekeyed/..',
                          '/nix/store/source/private/secrets/rekeyed/.',
                          '/nix/store/source/secrets/rekeyed',
                          '/nix/store/source/secrets/rekeyed/..',
                          '/nix/store/source/secrets/rekeyed/.',
                          '/nix/store/source/secrets/rekeyed/fixture/../../outside']:
            with self.subTest(directory=directory):
                self.log.unlink(missing_ok=True)
                result = self.invoke('--rekey', '-n', overrides={'TEST_REKEY_DIRECTORY': directory})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('rekey storage', result.stderr)
                self.assertEqual(len(self.calls()), 1)

    def test_rekey_metadata_failure_aborts_before_running_app(self):
        result = self.invoke('--rekey', overrides={'TEST_NIX_EVAL_STATUS': '29'})
        self.assertEqual(result.returncode, 29, result.stderr)
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.initial)

    def test_rekey_uses_local_darwin_system(self):
        Path(self.env['TEST_REKEY_IDENTITY']).write_text('synthetic identity\n')
        result = self.invoke('--rekey', '-n', overrides={'TEST_OS': 'Darwin', 'TEST_ARCH': 'arm64'})
        self.assert_success(result)
        self.assertIn('.?submodules=1#agenix-rekey-homes."alice@workstation-aarch64-darwin".aarch64-darwin.rekey',
                      self.calls()[1]['args'])

    def test_remote_identity_mismatch_prevents_rekey(self):
        result = self.invoke('--target-host', 'server', '--rekey',
                             overrides={'TEST_CONFIG_USER': 'bob'})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('does not match', result.stderr)
        self.assertEqual(len(self.calls()), 1)

    def test_list_and_rekey_are_mutually_exclusive(self):
        result = self.invoke('--list', '--rekey')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])
        self.assertEqual(self.git('diff', '--cached', '--name-only'), '')

    def test_no_submodule_is_required(self):
        self.git("rm", "-f", "support")
        self.git("commit", "-m", "remove fixture submodule")
        self.assert_success(self.invoke("--no-push", "-m", "home update"))
        self.assertEqual(self.git("log", "-1", "--format=%B"), "home update")


if __name__ == "__main__":
    unittest.main()
