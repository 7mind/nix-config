#!/usr/bin/env python3
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import tempfile
import unittest
import sys


@unittest.skipUnless(sys.platform == "linux", "Persistent NixOS profile integration requires Linux")
class HomeManagerPersistenceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="hm-persistence-")
        cls.addClassCleanup(cls.directory.cleanup)
        cls.root = Path(cls.directory.name)
        cls.project = Path(__file__).resolve().parents[1]
        cls.home = cls.root / "home"
        cls.home.mkdir()
        (cls.home / ".local/state/nix/profiles").mkdir(parents=True)
        cls.username = pwd.getpwuid(os.getuid()).pw_name
        state_directory = Path(os.environ.get("NIX_STATE_DIR", "/nix/var/nix"))
        daemon_socket = os.environ.get("NIX_DAEMON_SOCKET_PATH", str(state_directory / "daemon-socket/socket"))
        store_uri = os.environ.get("NIX_REMOTE", "daemon")
        if store_uri == "daemon":
            store_uri = f"unix://{daemon_socket}"
        cls.environment = dict(os.environ, HOME=str(cls.home), USER=cls.username, LOGNAME=cls.username,
                               HOME_MANAGER_BACKUP_EXT="hmbak", NIX_STATE_DIR=str(cls.root / "nix-state"),
                               NIX_REMOTE=store_uri)
        result = subprocess.run([
            "nix-build", str(cls.project / "tests/home-manager-persistence-fixture.nix"),
            "--argstr", "projectPath", str(cls.project),
            "--argstr", "username", cls.username,
            "--argstr", "homeDirectory", str(cls.home), "--no-out-link",
            "-A", "old", "-A", "new", "-A", "failing",
        ], text=True, capture_output=True)
        if result.returncode != 0:
            raise RuntimeError(result.stdout + result.stderr)
        cls.old, cls.new, cls.failing = map(Path, result.stdout.splitlines())
        cls.script = cls.project / "pkg/home-manager-switch/profile.sh"
        cls.bin = cls.root / "dummy-bin"
        cls.bin.mkdir()
        dummy = cls.bin / "nix-env"
        dummy.write_text('''#!/usr/bin/env python3
import os
from pathlib import Path
import sys
if sys.argv[1:] == ["-q"]:
    sys.exit(0)
profile = Path(sys.argv[2])
generation = sys.argv[4]
versions = list(profile.parent.glob(profile.name + "-*-link"))
version = profile.with_name(f"{profile.name}-{len(versions) + 1}-link")
version.symlink_to(generation)
temporary = profile.with_name(profile.name + ".new")
temporary.symlink_to(version.name)
os.replace(temporary, profile)
''')
        dummy.chmod(0o755)
        for name in ["nix", "nix-build", "nix-store"]:
            (cls.bin / name).symlink_to(shutil.which(name))

    def run_profile(self, environment, *args, success=True):
        result = subprocess.run(["bash", str(self.script), *map(str, args)],
                                env=environment, text=True, capture_output=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def select_system(self, environment, profile, generation, system, action):
        with tempfile.NamedTemporaryFile(mode="w", dir=self.root, delete=False) as request:
            request.write(f"{system}\n{action}\n{generation / 'nixos-generation'}\n")
        self.run_profile(environment, "system", profile, request.name)
        return Path(request.name)

    def setting(self):
        return (self.home / ".hm-test-setting").read_text()

    def test_switch_boot_system_switch_and_rollback(self):
        for adapter in ["dummy", "production"]:
            with self.subTest(adapter=adapter):
                directory = self.root / adapter
                directory.mkdir()
                profile = directory / "smind-home"
                system_a = directory / "system-a"
                system_b = directory / "system-b"
                environment = dict(self.environment)
                if adapter == "dummy":
                    environment["PATH"] = f"{self.bin}:{os.environ['PATH']}"

                self.select_system(environment, profile, self.old, system_a, "boot")
                self.assertEqual(profile.resolve(), (self.old / "nixos-generation").resolve())
                self.run_profile(environment, "activate", profile)
                self.assertEqual(self.setting(), "old")

                self.run_profile(environment, "switch", profile, self.new / "nixos-generation")
                self.assertEqual(profile.resolve(), (self.new / "nixos-generation").resolve())
                self.assertEqual(self.setting(), "new")
                selected = profile.resolve()

                self.select_system(environment, profile, self.old, system_a, "boot")
                self.run_profile(environment, "activate", profile)
                self.assertEqual(profile.resolve(), selected)
                self.assertEqual(self.setting(), "new")
                package = subprocess.check_output([str(profile / "home-path/bin/hm-fixture-tool")], text=True)
                self.assertEqual(package.strip(), "new")

                request = self.select_system(environment, profile, self.old, system_a, "switch")
                self.run_profile(environment, "activate", profile)
                self.assertEqual(self.setting(), "old")

                self.run_profile(environment, "switch", profile, self.new / "nixos-generation")
                self.run_profile(environment, "system", profile, request)
                self.run_profile(environment, "activate", profile)
                self.assertEqual(profile.resolve(), (self.new / "nixos-generation").resolve())
                self.assertEqual(self.setting(), "new")

                self.select_system(environment, profile, self.old, system_a, "switch")
                self.run_profile(environment, "activate", profile)
                self.assertEqual(self.setting(), "old")

                self.select_system(environment, profile, self.new, system_b, "boot")
                self.run_profile(environment, "activate", profile)
                self.assertEqual(self.setting(), "new")

                self.select_system(environment, profile, self.old, system_a, "boot")
                self.run_profile(environment, "activate", profile)
                self.assertEqual(self.setting(), "old")

                selected = (self.failing / "nixos-generation").resolve()
                result = self.run_profile(environment, "switch", profile, selected, success=False)
                self.assertEqual(result.returncode, 17)
                self.assertEqual((self.home / ".hm-test-new-only").read_text(), "failing")
                self.assertEqual(profile.resolve(), selected)
                self.assertEqual(self.setting(), "failing")

                self.select_system(environment, profile, self.old, system_a, "boot")
                self.assertEqual(profile.resolve(), selected)
                result = self.run_profile(environment, "activate", profile, success=False)
                self.assertEqual(result.returncode, 17)
                self.assertEqual(profile.resolve(), selected)
                self.assertEqual(self.setting(), "failing")

    def test_nixos_switch_requires_installed_integration(self):
        marker = self.root / "NIXOS"
        marker.touch()
        result = subprocess.run([
            str(self.new / "switch-home"), str(self.new), str(self.root / "missing"), str(marker),
        ], text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("full NixOS switch first", result.stderr)

    def test_nixos_switch_uses_selected_profile(self):
        directory = self.root / "integration"
        directory.mkdir()
        profile = directory / "smind-home"
        (directory / self.username).write_text(f"{profile}\n")
        marker = directory / "NIXOS"
        marker.touch()
        environment = dict(self.environment)
        self.select_system(environment, profile, self.old, directory / "system", "boot")
        result = subprocess.run([
            str(self.new / "switch-home"), str(self.new), str(directory), str(marker),
        ], env=environment, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(profile.resolve(), (self.new / "nixos-generation").resolve())
        self.assertEqual(self.setting(), "new")


if __name__ == "__main__":
    unittest.main()
