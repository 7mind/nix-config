import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SOURCE = Path(os.environ.get("NIX_CONFIG_SOURCE", Path(__file__).resolve().parents[1]))


class HomeSwitchSudoTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="home-switch-sudo-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.generation = self.root / "generation"
        self.generation.mkdir()
        self.manifest = self.generation / "refresh-user-secrets.json"
        self.manifest.write_text('[{"destination":"tester/token"}]\n')
        self.profiles = self.root / "profiles"
        self.profiles.mkdir()
        (self.profiles / "tester").write_text("/fixture/profile\n")
        self.marker = self.root / "NIXOS"
        self.marker.touch()
        self.events = self.root / "events"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.executable(self.bin / "id", 'printf "tester\\n"\n')
        for command in ("cat", "readlink"):
            (self.bin / command).symlink_to(shutil.which(command))
        self.executable(self.bin / "profile", 'printf "profile\\n" >> "$EVENTS"\n')
        self.helper = self.bin / "system-refresh"
        self.bundled_helper = self.bin / "bundled-refresh"
        for helper in (self.helper, self.bundled_helper):
            self.executable(helper, 'IFS= read -r manifest\nprintf "%s\\n" "$manifest" >> "$EVENTS"\nexit "${REFRESH_EXIT:-0}"\n')
        self.installed = self.bin / "refresh-user-secrets"
        self.installed.symlink_to(self.helper)
        self.executable(self.generation / "activate", 'printf "activate\\n" >> "$EVENTS"\n')
        expression = f'''
          import {json.dumps(str(SOURCE / "lib/home-switch.nix"))} {{
            pkgs = {{
              lib.optionalString = condition: text: if condition then text else "";
              lib.getExe = package: package.exe;
              coreutils = {json.dumps(str(self.root))};
              stdenv.hostPlatform.isLinux = true;
              callPackage = path: _: {{
                exe = if builtins.baseNameOf path == "home-age-refresh" then {json.dumps(str(self.bundled_helper))}
                      else {json.dumps(str(self.bin / "profile"))};
              }};
              writeShellApplication = application: application.text;
            }};
            home = {{
              activationPackage = {json.dumps(str(self.generation))};
              extendModules = _: {{ activationPackage = {json.dumps(str(self.generation))}; }};
            }};
          }}
        '''
        script = subprocess.check_output([
            "nix", "--extra-experimental-features", "nix-command", "eval", "--offline", "--impure", "--raw", "--expr", expression
        ], env=dict(os.environ, NIX_REMOTE="dummy://"), text=True)
        self.environment = dict(os.environ, EVENTS=str(self.events), HELPER=str(self.helper))
        self.sudo = self.root / "sudo"
        self.executable(self.sudo, '''[[ "${DENY_SUDO:-0}" == 0 && $# == 2 && "$1" == -- && "$2" == "$HELPER" ]] || exit 19
exec "$2"
''')
        self.switch = self.root / "switch-home"
        self.executable(self.switch, script.replace("/run/wrappers/bin/sudo", str(self.sudo)).replace(
            "/run/current-system/sw/bin/refresh-user-secrets", str(self.installed)))

    def executable(self, path, body):
        path.write_text(f'#!{shutil.which("bash")}\nset -euo pipefail\n{body}')
        path.chmod(0o755)

    def run_switch(self, **environment):
        return subprocess.run([str(self.switch), str(self.profiles), str(self.marker)],
                              env=dict(self.environment, **environment), text=True, capture_output=True)

    def observed(self):
        return self.events.read_text().splitlines() if self.events.exists() else []

    def test_switch_passes_manifest_to_system_helper(self):
        result = self.run_switch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.observed(), [self.manifest.read_text().strip(), "profile"])

    def test_refresh_failure_prevents_profile_switch(self):
        result = self.run_switch(REFRESH_EXIT="23")
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual(self.observed(), [self.manifest.read_text().strip()])

    def test_denied_sudo_prevents_profile_switch(self):
        result = self.run_switch(DENY_SUDO="1")
        self.assertEqual(result.returncode, 19)
        self.assertEqual(self.observed(), [])

    def test_missing_system_helper_uses_bundled_helper(self):
        self.installed.unlink()
        result = self.run_switch(HELPER=str(self.bundled_helper))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.observed(), [self.manifest.read_text().strip(), "profile"])

    def test_bundled_helper_still_requires_sudo_permission(self):
        self.installed.unlink()
        result = self.run_switch(HELPER=str(self.bundled_helper), DENY_SUDO="1")
        self.assertEqual(result.returncode, 19)
        self.assertEqual(self.observed(), [])

    def test_no_manifest_needs_no_sudo(self):
        self.manifest.unlink()
        result = self.run_switch(DENY_SUDO="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.observed(), ["profile"])

    def test_without_host_marker_uses_normal_activation(self):
        self.marker.unlink()
        result = self.run_switch(DENY_SUDO="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.observed(), ["activate"])


if __name__ == "__main__":
    unittest.main()
