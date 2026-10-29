import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path

from flurry.nix import Nix
from flurry.process import FlurryError, Runner


class ForbiddenRunner:
    def run(self, arguments, cwd):
        raise AssertionError("Subprocess executed before symlink preflight")


class NixLockTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="flurry-nix-")
        self.path = Path(self.temporary.name)
        self.nix = Nix(Runner(dict(os.environ), 60))

    def tearDown(self):
        self.temporary.cleanup()

    def lock(self, nodes):
        (self.path / "flake.lock").write_text(json.dumps({"version": 7, "root": "root", "nodes": nodes}))

    def test_direct_locked_sources_resolve_nested_follows_and_nonflake(self):
        self.lock({
            "root": {"inputs": {"provider": "provider", "alias": ["provider", "nested"], "nonflake": "source", "tarball": "tarball"}},
            "provider": {"locked": {"type": "github", "owner": "owner", "repo": "provider", "rev": "a" * 40}, "inputs": {"nested": "source"}},
            "source": {"locked": {"type": "git", "url": "https://example.com/group/source.git", "rev": "b" * 40, "dir": "nix"}, "flake": False},
            "tarball": {"locked": {"type": "tarball", "url": "https://example.com/source.tar.gz"}},
        })
        locked = self.nix.locked_inputs(self.path)
        self.assertEqual(set(locked), {"provider", "alias", "nonflake"})
        self.assertEqual(locked["alias"], locked["nonflake"])
        self.assertEqual(locked["alias"].rev, "b" * 40)
        self.assertEqual(locked["alias"].directory, "nix")
        self.assertFalse(locked["alias"].flake)

    def test_symlink_boundaries_are_rejected_before_subprocess_or_external_reads(self):
        outside = self.path / "outside"
        outside.mkdir()
        checkout = self.path / "checkout"
        checkout.mkdir()
        target = outside / "lock"
        original = b'{"version":7,"root":"root","nodes":{"root":{}}}'
        target.write_bytes(original)
        (checkout / "flake.lock").symlink_to(target)
        guarded = Nix(ForbiddenRunner())
        for operation in (lambda: guarded.update(checkout, ("a",)), lambda: guarded.check(checkout, False), lambda: guarded.locked_inputs(checkout)):
            with self.subTest(operation=operation), self.assertRaisesRegex(FlurryError, "symlink"):
                operation()
            self.assertEqual(target.read_bytes(), original)
        (checkout / "flake.lock").unlink()
        declaration = outside / "flake.nix"
        declaration.write_text('{ outputs = _: {}; }')
        (checkout / "flake.nix").symlink_to(declaration)
        with self.assertRaisesRegex(FlurryError, "symlink"):
            guarded.inputs(checkout)

    def test_cyclic_missing_and_malformed_lock_nodes_fail_explicitly(self):
        for nodes in (
            {"root": {"inputs": {"a": ["b"], "b": ["a"]}}},
            {"root": {"inputs": {"a": "missing"}}},
            {"root": {"inputs": {"a": ["missing"]}}},
            {"root": {"inputs": {"a": "a"}}, "a": {}},
        ):
            with self.subTest(nodes=nodes):
                self.lock(nodes)
                with self.assertRaises(FlurryError):
                    self.nix.locked_inputs(self.path)


@unittest.skipUnless(shutil.which("nix"), "real Nix unavailable")
class RealNixTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="flurry-real-nix-")
        self.path = Path(self.temporary.name)
        self.runner = Runner(dict(os.environ), 90)
        self.nix = Nix(self.runner)

    def tearDown(self):
        self.temporary.cleanup()

    def commit(self, path):
        self.runner.git(path, "add", ".")
        self.runner.git(path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "fixture")

    def repository(self, name, declaration):
        path = self.path / name
        path.mkdir()
        self.runner.run(["git", "init", "--initial-branch=main", str(path)], None)
        (path / "flake.nix").write_text(declaration)
        self.commit(path)
        return path

    def test_declarations_are_evaluated_without_outputs_nixconfig_or_lock_writes(self):
        path = self.repository("declarations", '''{
          inputs.hosted.url = "github:owner/repository/main";
          inputs.hosted.inputs.alias.follows = "source";
          inputs.source = { type = "git"; url = "file:///local/source"; ref = "main"; flake = false; };
          inputs.alias.follows = "hosted/source";
          nixConfig = throw "nixConfig must not be evaluated";
          outputs = throw "outputs must not be evaluated";
        }''')
        inputs = {item.name: item for item in self.nix.inputs(path)}
        self.assertEqual(inputs["hosted"].source.repository_id, "github.com/owner/repository")
        self.assertEqual(inputs["alias"].follows, "hosted/source")
        self.assertFalse(inputs["source"].source.flake)
        self.assertFalse((path / "flake.lock").exists())
        self.assertEqual(self.runner.git_text(path, "status", "--porcelain"), "")

    def test_import_from_derivation_is_disabled(self):
        path = self.repository("ifd", '''{
          inputs.source.url = import (builtins.derivation {
            name = "forbidden-declaration"; system = builtins.currentSystem;
            builder = "/bin/sh"; args = [ "-c" "echo 1 > $out" ];
          });
          outputs = _: {};
        }''')
        with self.assertRaisesRegex(FlurryError, "allow-import-from-derivation|cannot build|not allowed|disabled"):
            self.nix.inputs(path)

    def test_targeted_refresh_propagates_local_chain_exactly_and_is_idempotent(self):
        a = self.repository("a", '{ outputs = _: { value = 1; }; }')
        a_url = "git+" + a.as_uri() + "?ref=main"
        b = self.repository("b", '{ inputs.a.url = "' + a_url + '"; outputs = _: {}; }')
        self.nix.update(b, ("a",))
        self.commit(b)
        b_url = "git+" + b.as_uri() + "?ref=main"
        c = self.repository("c", '{ inputs.a.url = "' + a_url + '"; inputs.b.url = "' + b_url + '"; inputs.b.inputs.a.follows = "a"; outputs = _: {}; }')
        self.nix.update(c, ("a", "b"))
        original = self.nix.locked_inputs(c)["a"].rev
        (a / "flake.nix").write_text('{ outputs = _: { value = 2; }; }')
        self.commit(a)
        expected = self.runner.git_text(a, "rev-parse", "HEAD")
        self.assertNotEqual(original, expected)
        self.nix.update(b, ("a",))
        self.assertEqual(self.nix.locked_inputs(b)["a"].rev, expected)
        self.commit(b)
        self.nix.update(c, ("a", "b"))
        self.assertEqual(self.nix.locked_inputs(c)["a"].rev, expected)
        self.assertEqual(self.nix.locked_inputs(c)["b"].rev, self.runner.git_text(b, "rev-parse", "HEAD"))
        lock = (c / "flake.lock").read_bytes()
        self.nix.update(c, ("a", "b"))
        self.assertEqual((c / "flake.lock").read_bytes(), lock)
        self.nix.check(c, False)
