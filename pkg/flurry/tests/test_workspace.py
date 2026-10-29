import os
import shutil
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path

from flurry.nix import Input
from flurry.process import FlurryError, Runner
from flurry.source import parse_source
from flurry.workspace import Repository, RepoSettings, build_graph, discover, load_config


class DeclaredInputs:
    def __init__(self, declarations):
        self.declarations = declarations

    def inputs(self, path, *, base=None):
        return self.declarations.get(path.name, ())


class WorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="flurry-graph-")
        self.root = Path(self.temporary.name)
        self.runner = Runner(dict(os.environ), 30)

    def tearDown(self):
        self.temporary.cleanup()

    def repository(self, name, source, excluded=False):
        path = self.root / name
        path.mkdir()
        (path / "flake.nix").write_text('{ outputs = _: {}; }')
        settings = RepoSettings(name, path, source=parse_source(source, self.root))
        return Repository(name, path, path / ".git", "main", "a" * 40, source, None, excluded, settings)

    def input(self, name, source):
        return Input(name, parse_source(source, self.root), None)

    def initialize(self, path, flake=True):
        path.mkdir()
        self.runner.run(["git", "init", "--initial-branch=main", str(path)], None)
        if flake:
            (path / "flake.nix").write_text('{ outputs = _: {}; }')
        (path / "file").write_text("initial")
        self.runner.git(path, "add", ".")
        self.runner.git(path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "initial")

    def test_strict_local_overlay_adds_exclusions_and_overrides_fields(self):
        (self.root / "flurry.toml").write_text('version = 1\nexclude = ["wt-*"]\n[repositories.app]\npath = "app"\nrebase_onto = "origin/main"\npush_remote = "origin"\n')
        (self.root / "flurry.local.toml").write_text('exclude = ["archive"]\n[repositories.app]\npush_remote = "publish"\nsource = "github:owner/app"\n')
        config = load_config(self.root, ("private-*",))
        self.assertEqual(config.excludes, ("wt-*", "archive", "private-*"))
        self.assertEqual(config.repositories[0].rebase_onto, "origin/main")
        self.assertEqual(config.repositories[0].push_remote, "publish")
        self.assertEqual(config.repositories[0].path, self.root / "app")
        self.assertEqual(config.repositories[0].source.repository_id, "github.com/owner/app")

    def test_invalid_configuration_does_not_silently_broaden_scope(self):
        for contents in ('exclude = "app"', 'unknown = true', 'version = true', 'exclude = ["../app"]', '[repositories.app]\npush_remtoe = "origin"', '[repositories.app]\npath = "--unsafe"'):
            with self.subTest(contents=contents):
                (self.root / "flurry.toml").write_text(contents)
                with self.assertRaises(FlurryError):
                    load_config(self.root, ())

    def test_dangling_configuration_symlink_fails_closed(self):
        for name in ("flurry.toml", "flurry.local.toml"):
            with self.subTest(name=name):
                path = self.root / name
                path.symlink_to(self.root / "missing")
                with self.assertRaisesRegex(FlurryError, "Cannot read configuration"):
                    load_config(self.root, ())
                path.unlink()

    def test_full_identity_graph_orders_providers_and_keeps_follows_aliases_out(self):
        a = self.repository("a", "github:owner/a")
        b = self.repository("b", "github:owner/b")
        c = self.repository("c", "github:owner/c")
        other = self.repository("other", "github:other/a")
        nix = DeclaredInputs({"b": (self.input("a", "git+https://github.com/owner/a.git"),), "c": (self.input("b", "github:owner/b"), self.input("a", "github:owner/a"), Input("alias", None, "b/a"))})
        graph = build_graph((c, other, b, a), nix)
        self.assertLess(graph.order.index(a), graph.order.index(b))
        self.assertLess(graph.order.index(b), graph.order.index(c))
        self.assertEqual(len(graph.edges), 3)
        self.assertFalse(any(edge.provider == other for edge in graph.edges))

    def test_excluded_provider_is_visible_frozen_boundary(self):
        provider = self.repository("provider", "github:owner/provider", True)
        consumer = self.repository("consumer", "github:owner/consumer")
        graph = build_graph((consumer, provider), DeclaredInputs({"consumer": (self.input("p", "github:owner/provider"),)}))
        self.assertEqual(graph.order, (consumer,))
        self.assertTrue(graph.edges[0].provider.excluded)

    def test_cycles_report_edges_but_fixed_revisions_are_boundaries(self):
        a = self.repository("a", "github:owner/a")
        b = self.repository("b", "github:owner/b")
        declarations = {"a": (self.input("to-b", "github:owner/b"),), "b": (self.input("to-a", "github:owner/a"),)}
        with self.assertRaisesRegex(FlurryError, "a/to-b.*b/to-a"):
            build_graph((a, b), DeclaredInputs(declarations))
        declarations["b"] = (self.input("old-a", "github:owner/a/" + "a" * 40),)
        graph = build_graph((a, b), DeclaredInputs(declarations))
        self.assertEqual(graph.order, (b, a))
        self.assertEqual(len(graph.edges), 2)

    def test_ambiguous_worktrees_require_ref_or_exclusion(self):
        main = self.repository("main", "github:owner/provider")
        topic = replace(self.repository("topic", "github:owner/provider"), branch="topic")
        consumer = self.repository("consumer", "github:owner/consumer")
        with self.assertRaisesRegex(FlurryError, "Ambiguous providers"):
            build_graph((main, topic, consumer), DeclaredInputs({"consumer": (self.input("p", "github:owner/provider"),)}))
        graph = build_graph((main, topic, consumer), DeclaredInputs({"consumer": (self.input("p", "github:owner/provider/topic"),)}))
        self.assertEqual(graph.edges[0].provider, topic)

    def test_subflakes_and_unsupported_inputs_report_scope(self):
        provider = self.repository("provider", "github:owner/provider")
        consumer = self.repository("consumer", "github:owner/consumer")
        with self.assertRaisesRegex(FlurryError, "Unsupported subflake"):
            build_graph((provider, consumer), DeclaredInputs({"consumer": (self.input("p", "github:owner/provider?dir=nix"),)}))
        graph = build_graph((consumer,), DeclaredInputs({"consumer": (Input("local", None, None),)}))
        self.assertEqual(graph.edges, ())

    @unittest.skipUnless(shutil.which("nix"), "real Nix unavailable")
    def test_discovery_deduplicates_aliases_but_not_linked_worktrees(self):
        main = self.root / "main"
        self.initialize(main)
        (self.root / "alias").symlink_to(main, target_is_directory=True)
        topic = self.root / "topic"
        self.runner.git(main, "worktree", "add", "-b", "topic", str(topic))
        nested = self.root / "unrelated"
        nested.mkdir()
        self.initialize(nested / "hidden")
        repositories = discover(load_config(self.root, ("topic",)), self.runner)
        self.assertEqual({repository.path for repository in repositories}, {main, topic})
        self.assertEqual({repository.name for repository in repositories}, {"main", "topic"})
        self.assertEqual(repositories[0].common_dir, repositories[1].common_dir)
        self.assertEqual(sum(repository.excluded for repository in repositories), 1)

    @unittest.skipUnless(shutil.which("nix"), "real Nix unavailable")
    def test_generic_initialized_submodule_discovery(self):
        source = self.root / "submodule-source"
        self.initialize(source)
        parent = self.root / "parent"
        self.initialize(parent)
        self.runner.git(parent, "-c", "protocol.file.allow=always", "submodule", "add", str(source), "vendor/dependency")
        repositories = discover(load_config(self.root, ()), self.runner)
        self.assertIn(parent / "vendor/dependency", {repository.path for repository in repositories})

    def test_configured_paths_and_aliases_cannot_escape_workspace(self):
        for path in ("..", str(self.root.parent)):
            with self.subTest(path=path):
                (self.root / "flurry.toml").write_text('[repositories.escape]\npath = "' + path + '"\n')
                with self.assertRaisesRegex(FlurryError, "escapes workspace"):
                    load_config(self.root, ())
        (self.root / "flurry.toml").unlink()
        (self.root / "escape").symlink_to(self.root.parent, target_is_directory=True)
        (self.root / "flurry.toml").write_text('[repositories.escape]\npath = "escape"\n')
        with self.assertRaisesRegex(FlurryError, "escapes workspace"):
            load_config(self.root, ())

    def test_unmatched_exclusion_is_an_explicit_error(self):
        with self.assertRaisesRegex(FlurryError, "matched no repository"):
            discover(load_config(self.root, ("typo-*",)), self.runner)
