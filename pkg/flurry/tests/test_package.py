import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path

from flurry.process import Runner


@unittest.skipUnless(shutil.which("nix") and os.environ.get("FLURRY_NIXPKGS_PATH"), "package source check needs explicit pinned FLURRY_NIXPKGS_PATH")
class PackageTests(unittest.TestCase):
    def test_package_source_excludes_worktrees_and_private_state(self):
        with tempfile.TemporaryDirectory(prefix="flurry-package-") as temporary:
            root = Path(temporary)
            shutil.copyfile(Path(__file__).resolve().parents[1] / "package.nix", root / "package.nix")
            for name in (".worktrees", ".flurry", "__pycache__"):
                (root / name).mkdir()
                (root / name / "private-marker").write_text("not package source")
            (root / "flurry.local.toml").write_text("private config")
            pkgs_path = json.dumps(os.environ["FLURRY_NIXPKGS_PATH"])
            project = json.dumps(str(root / "package.nix"))
            expression = f'''let pkgs = import (builtins.toPath {pkgs_path}) {{}};
              package = pkgs.callPackage (builtins.toPath {project}) {{}};
              in map (name: builtins.pathExists (package.src + "/" + name))
                [ ".worktrees/private-marker" ".flurry/private-marker" "__pycache__/private-marker" "flurry.local.toml" ]'''
            result = Runner(os.environ, 60).text(["nix", "--extra-experimental-features", "nix-command", "eval", "--offline", "--impure", "--json", "--expr", expression], None)
            self.assertEqual(json.loads(result), [False, False, False, False])
