import dataclasses
import os
import tempfile
import unittest
from pathlib import Path

from flurry.process import FlurryError, Runner
from flurry.source import parse_source


class SourceTests(unittest.TestCase):
    def test_transports_share_full_repository_identity(self):
        sources = [parse_source(value, Path.cwd()) for value in (
            "github:Owner/Repo", "git+https://github.com/owner/repo.git",
            "git+ssh://git@github.com/owner/repo.git", "git@github.com:Owner/Repo.git",
            "git+https://github.com:443/Owner/Repo.git", "git+ssh://git@github.com:22/Owner/Repo.git",
        )]
        self.assertEqual({source.repository_id for source in sources}, {"github.com/owner/repo"})
        self.assertNotEqual(sources[0].repository_id, parse_source("github:other/repo", Path.cwd()).repository_id)
        with self.assertRaises(dataclasses.FrozenInstanceError):
            sources[0].ref = "main"

    def test_gitlab_attribute_set_and_subdirectory(self):
        source = parse_source({"type": "gitlab", "owner": "group/subgroup", "repo": "project", "host": "gitlab.example", "ref": "stable", "dir": "nix/flake", "flake": False}, Path.cwd())
        self.assertEqual(source.repository_id, "gitlab.example/group/subgroup/project")
        self.assertEqual(source.project, "group/subgroup/project")
        self.assertFalse(source.flake)
        self.assertEqual(source.directory, "nix/flake")
        self.assertEqual(source.ref, "stable")
        self.assertEqual(parse_source(source.url, Path.cwd()), dataclasses.replace(source, flake=True))

    def test_file_source_resolves_relative_path(self):
        source = parse_source("git+file:dependency?ref=main", Path.cwd())
        self.assertEqual(source.repository_id, (Path.cwd() / "dependency").resolve().as_uri())
        self.assertEqual(source.clone_url, source.repository_id)

    def test_raw_local_git_origins_match_file_uris_including_relative_spaces(self):
        with tempfile.TemporaryDirectory(prefix="flurry-source-") as temporary:
            base = Path(temporary)
            path = base / "bare remote.git"
            runner = Runner(dict(os.environ), 30)
            runner.run(["git", "init", "--bare", str(path)], None)
            expected = parse_source("git+" + path.as_uri(), base)
            self.assertEqual(parse_source(str(path), base), expected)
            self.assertEqual(parse_source("./bare remote.git", base), expected)
            self.assertIsNone(parse_source("path:" + path.as_uri(), base))
            self.assertIsNone(parse_source({"type": "path", "path": str(path)}, base))

    def test_percent_encoded_project_identity_round_trips(self):
        for value in ("git+https://example.com/group/name%252F.git", "git+ssh://git@example.com/group/name%252F.git"):
            source = parse_source(value, Path.cwd())
            self.assertEqual(parse_source(source.url, Path.cwd()), source)

    def test_revision_is_not_branch_and_dir_is_not_identity(self):
        revision = "a" * 40
        source = parse_source(f"github:owner/repo/{revision}?dir=flake", Path.cwd())
        self.assertEqual(source.rev, revision)
        self.assertIsNone(source.ref)
        self.assertEqual(source.repository_id, "github.com/owner/repo")

    def test_known_unsupported_sources_are_explicit(self):
        for value in ("path:../dependency", {"type": "tarball", "url": "https://example.com/archive.tar.gz"}):
            with self.subTest(value=value):
                self.assertIsNone(parse_source(value, Path.cwd()))

    def test_unsafe_and_malformed_sources_are_rejected(self):
        for value in (
            "nixpkgs", {"type": "indirect", "id": "nixpkgs"}, "indirect:nixpkgs",
            "--upload-pack=evil", "git+https://token@example.com/repo.git", "git+ssh://git:secret@example.com/repo.git",
            "git+https://example.com/repo.git?upload-pack=evil", "github:owner/repo?dir=../escape",
            "github:owner/repo?ref=--evil", "github:owner/repo?ref=main&ref=other", "github:owner/repo\n",
            "ftp://example.com/repo", "evil+https://example.com/repo.git",
            "github://owner/repo", "github:owner/repo/main^", "git+ssh://-oProxyCommand=evil@example.com/repo.git", "git+ssh://%0a@example.com/repo.git",
            "git+file:///tmp/repo%00", "git+file:///tmp/repo%0a",
            "git+https://[bad/repo.git", "git+https://example.com/repo.git?ref=main%00", {"type": "github", "owner": "owner", "repo": "repo", "rfe": "main"},
            "git+https://example.com/repo%0a.git", "github:owner/repo?rev=main", {"url": "github:owner/repo", "flake": "false"},
        ):
            with self.subTest(value=value), self.assertRaises(FlurryError):
                parse_source(value, Path.cwd())
