#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class SetupHomeManagerTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="setup-hm-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.setup = self.root / "setup"
        shutil.copy2(Path(__file__).resolve().parents[1] / "setup", self.setup)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "commands"
        self.generation = self.root / "home-generation"
        self.generation.mkdir()
        activate = self.generation / "activate"
        activate.write_text('#!/usr/bin/env bash\nprintf "activate:%s\\n" "$HOME_MANAGER_BACKUP_EXT" >> "$TEST_LOG"\n')
        activate.chmod(0o755)
        switch = self.generation / "switch-home"
        switch.write_text('#!/usr/bin/env bash\nexport HOME_MANAGER_BACKUP_EXT=hmbak\nexec "$1/activate"\n')
        switch.chmod(0o755)
        command = self.bin / "command"
        command.write_text('''#!/usr/bin/env bash
set -eu
name="${0##*/}"
printf '%s' "$name" >> "$TEST_LOG"
printf ' <%s>' "$@" >> "$TEST_LOG"
printf '\\n' >> "$TEST_LOG"
case "$name" in
    uname)
        if [[ $# -gt 0 && "$1" == -m ]]; then printf '%s\\n' "$TEST_ARCH"; else printf '%s\\n' "$TEST_PLATFORM"; fi
        ;;
    hostname) printf '%s\\n' "$TEST_HOST" ;;
    id) printf '%s\\n' "$TEST_USER" ;;
    nix)
        case "$1" in
            eval)
                case "$2" in
                    *'#homeConfigurations') printf '%s\\n' "$TEST_HOMES" ;;
                    *'#hostMeta') printf '%s\\n' "$TEST_HOST_META" ;;
                    *) exit 90 ;;
                esac
                ;;
            build)
                while [[ $# -gt 0 ]]; do
                    if [[ "$1" == --out-link ]]; then
                        if [[ "$2" == "$TEST_DIRECTORY/"* ]]; then ln -s "$TEST_GENERATION" "$2"; fi
                        break
                    fi
                    shift
                done
                ;;
            copy) ;;
            *) exit 91 ;;
        esac
        ;;
    mkdir)
        if [[ "$2" != /nix/var/nix/gcroots/my-builds ]]; then "$TEST_MKDIR" "$@"; fi
        ;;
    git|touch|rm|sudo|ssh) ;;
    *) exit 92 ;;
esac
''')
        command.chmod(0o755)
        for name in ["nix", "git", "uname", "hostname", "id", "touch", "rm", "sudo", "ssh", "mkdir"]:
            (self.bin / name).symlink_to(command)
        self.env = dict(
            os.environ,
            PATH=f"{self.bin}:{os.environ['PATH']}",
            NIX_CONFIG_DEV_SHELL="1",
            XDG_STATE_HOME=str(self.root / "state"),
            TMPDIR=str(self.root),
            TEST_DIRECTORY=str(self.root),
            TEST_MKDIR=shutil.which("mkdir"),
            TEST_LOG=str(self.log),
            TEST_GENERATION=str(self.generation),
            TEST_HOST="pavel-fw",
            TEST_USER="pavel",
            TEST_PLATFORM="Linux",
            TEST_ARCH="x86_64",
            TEST_HOMES=json.dumps([
                "pavel@pavel-fw-x86_64", "pavel@pavel-am5-x86_64", "pavel@pavel-trx40-x86_64",
                "pavel@pavel-mba-m3-aarch64-darwin", "alex@ubuntu-x86_64",
            ]),
            TEST_HOST_META=json.dumps({"pavel-fw": {"platform": "linux", "group": "pavel", "fqn": None}}),
        )

    def run_setup(self, *args, success=True):
        result = subprocess.run(
            ["bash", str(self.setup), "--offline", "--no-git", "--no-cache", "--no-resock", *args],
            env=self.env, text=True, capture_output=True,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result, self.log.read_text()

    def assert_home_only(self, commands):
        self.assertNotIn("#hostMeta", commands)
        self.assertNotIn("nixosConfigurations", commands)
        self.assertNotIn("darwinConfigurations", commands)
        self.assertNotIn("/nix/var/nix/profiles/system", commands)
        self.assertNotIn("switch-to-configuration", commands)

    def test_build_current_home(self):
        _, commands = self.run_setup("--hm-only")
        self.assert_home_only(commands)
        self.assertIn('#homeConfigurations."pavel@pavel-fw-x86_64".activationPackage', commands)
        self.assertIn(str(self.root / "state/nix-config/home-builds/pavel@pavel-fw-x86_64"), commands)
        self.assertNotIn("activate:", commands)

    def test_switch_current_home(self):
        _, commands = self.run_setup("--hm-only", "-s")
        self.assert_home_only(commands)
        self.assertIn("activate:hmbak", commands)
        self.assertNotIn("sudo", commands)

    def test_remote_switch_uses_user(self):
        _, commands = self.run_setup("--hm-only", "pavel-am5", "-s", "--host-override", "pavel-am5=am5.example", "-ncs")
        self.assert_home_only(commands)
        self.assertIn("<ssh-ng://pavel@am5.example?compress=true>", commands)
        self.assertIn("ssh <pavel@am5.example>", commands)
        self.assertIn("/switch-home>", commands)
        self.assertIn("</etc/smind/home-manager> </etc/NIXOS>", commands)
        self.assertNotIn("root@", commands)

    def test_darwin_export(self):
        self.env.update(TEST_HOST="pavel-mba-m3", TEST_PLATFORM="Darwin", TEST_ARCH="arm64")
        _, commands = self.run_setup("--hm-only", "-s")
        self.assert_home_only(commands)
        self.assertIn('#homeConfigurations."pavel@pavel-mba-m3-aarch64-darwin".activationPackage', commands)
        self.assertIn("activate:hmbak", commands)

    def test_home_without_os_export(self):
        self.env.update(TEST_HOST="ubuntu", TEST_USER="alex")
        _, commands = self.run_setup("--hm-only")
        self.assert_home_only(commands)
        self.assertIn('#homeConfigurations."alex@ubuntu-x86_64".activationPackage', commands)

    def test_missing_standalone_export(self):
        result, commands = self.run_setup("--hm-only", "ubuntu", success=False)
        self.assertIn("Unknown host 'ubuntu'", result.stderr)
        self.assert_home_only(commands)
        self.assertNotIn("nix <build>", commands)

    def test_group_builds_only_current_users_platform(self):
        _, commands = self.run_setup("--hm-only", "+pavel")
        self.assert_home_only(commands)
        self.assertEqual(commands.count("nix <build>"), 3)
        self.assertNotIn(".activationPackage", "\n".join(
            line for line in commands.splitlines() if "darwin" in line or "alex@" in line
        ))

    def test_ambiguous_host_exports_rejected(self):
        self.env["TEST_HOMES"] = json.dumps(["pavel@pavel-fw-x86_64", "pavel@pavel-fw-aarch64"])
        result, commands = self.run_setup("--hm-only", success=False)
        self.assertIn("Ambiguous standalone Home Manager exports", result.stderr)
        self.assert_home_only(commands)
        self.assertNotIn("nix <build>", commands)

    def test_os_options_rejected_before_build(self):
        for flag in ["--boot", "--rekey"]:
            with self.subTest(flag=flag):
                result, commands = self.run_setup("--hm-only", flag, success=False)
                self.assertIn("--hm-only", result.stderr)
                self.assertNotIn("nix <build>", commands)
                self.assertNotIn("nix <eval>", commands)

    def test_list_home_exports(self):
        result, commands = self.run_setup("--hm-only", "--list")
        self.assertIn("pavel-fw", result.stdout)
        self.assertIn("pavel-mba-m3", result.stdout)
        self.assertNotIn("ubuntu", result.stdout)
        self.assert_home_only(commands)

    def test_os_build_unchanged(self):
        _, commands = self.run_setup("pavel-fw")
        self.assertIn("#hostMeta", commands)
        self.assertIn("#nixosConfigurations.pavel-fw.config.system.build.toplevel", commands)
        self.assertNotIn("#homeConfigurations", commands)


if __name__ == "__main__":
    unittest.main()
