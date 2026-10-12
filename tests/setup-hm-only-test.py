#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


with tempfile.TemporaryDirectory(prefix="setup-hm-") as directory:
    root = Path(directory)
    shutil.copy2(Path(__file__).resolve().parents[1] / "setup", root / "setup")
    bin_directory = root / "bin"
    bin_directory.mkdir()
    log = root / "commands"
    stub = bin_directory / "stub"
    stub.write_text(f"#!{sys.executable}\n" + '''
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["TEST_LOG"], "a") as log:
    print(json.dumps([name, *args]), file=log)
if name in ("uname", "hostname", "id"):
    print(os.environ[{"uname": "TEST_ARCH" if args == ["-m"] else "TEST_PLATFORM", "hostname": "TEST_HOST", "id": "TEST_USER"}[name]])
elif name == "nix" and args[0] == "eval":
    if os.environ.get("TEST_EVAL_FAIL"):
        raise SystemExit("fixture nix eval failure")
    print(os.environ["TEST_HOMES"])
elif name == "nix" and args[0] == "build":
    target = pathlib.Path(args[args.index("--out-link") + 1])
    if target.is_relative_to(os.environ["TEST_ROOT"]):
        target.symlink_to(os.environ["TEST_PACKAGE"])
''')
    stub.chmod(0o755)
    for command in ("nix", "git", "uname", "hostname", "id", "touch", "rm", "sudo", "ssh", "switch-home"):
        (bin_directory / command).symlink_to(stub)
    homes = {f"{user}@{host}-{arch}": dict(hostname=host, username=user, platform=platform)
             for user, host, arch, platform in [
                 ("pavel", "pavel-fw", "x86_64", "linux"), ("pavel", "pavel-am5", "x86_64", "linux"),
                 ("pavel", "pavel-trx40", "x86_64", "linux"), ("pavel", "pavel-mba-m3", "aarch64-darwin", "darwin"),
                 ("alex", "ubuntu", "x86_64", "linux")]}
    env = dict(os.environ, PATH=f"{bin_directory}:{os.environ['PATH']}", NIX_CONFIG_DEV_SHELL="1",
               XDG_STATE_HOME=str(root / "state"), TEST_ROOT=str(root), TEST_PACKAGE=str(root),
               TEST_LOG=str(log), TEST_HOST="pavel-fw", TEST_USER="pavel", TEST_ARCH="x86_64",
               TEST_PLATFORM="Linux", TEST_HOMES=json.dumps(homes))
    for label, args, overrides, expected, error, builds in [
        ("build", [], {}, ["pavel@pavel-fw-x86_64", "state/nix-config/home-builds/pavel-fw"], "", 1),
        ("switch", ["-s"], {}, ["switch-home", "/etc/smind/home-manager", "/etc/NIXOS"], "", 1),
        ("remote", ["pavel-am5", "-s", "--host-override", "pavel-am5=am5.example", "-ncs"], {},
         ["ssh-ng://pavel@am5.example?compress=true", '"ssh", "pavel@am5.example"'], "", 1),
        ("darwin", ["-s"], dict(TEST_HOST="pavel-mba-m3", TEST_PLATFORM="Darwin", TEST_ARCH="arm64"),
         ["pavel@pavel-mba-m3-aarch64-darwin", "switch-home"], "", 1),
        ("no-os", [], dict(TEST_HOST="ubuntu", TEST_USER="alex"), ["alex@ubuntu-x86_64"], "", 1),
        ("missing", ["ubuntu"], {}, [], "Unknown host 'ubuntu'", 0),
        ("group", ["+pavel"], {}, ["pavel-fw", "pavel-am5", "pavel-trx40"], "", 3),
        ("ambiguous", [], dict(TEST_HOMES=json.dumps(homes | {"duplicate": homes["pavel@pavel-fw-x86_64"]})),
         [], "Ambiguous standalone Home Manager exports", 0),
        ("boot", ["--boot"], {}, [], "--hm-only is incompatible", 0),
        ("rekey", ["--rekey"], {}, [], "--hm-only is incompatible", 0),
        ("list", ["--list"], {}, ["pavel-fw", "pavel-mba-m3"], "", 0),
        ("eval-failure", [], dict(TEST_EVAL_FAIL="1"), [], "fixture nix eval failure", 0),
    ]:
        log.write_text("")
        shutil.rmtree(root / "state", ignore_errors=True)
        result = subprocess.run(["bash", root / "setup", "--offline", "--no-git", "--no-cache", "--no-resock",
                                 "--hm-only", *args],
                                env=env | overrides, text=True, capture_output=True)
        commands = log.read_text()
        assert (result.returncode == 0) == (not error), (label, result.stdout, result.stderr)
        assert commands.count('["nix", "build"') == builds, (label, commands)
        for fragment in [*expected, error]:
            assert fragment in commands + result.stdout + result.stderr, (label, fragment)
        assert not any(fragment in commands for fragment in ("#hostMeta", "nixosConfigurations", "darwinConfigurations", "sudo", "root@"))
        assert commands.count(".switchPackage") == builds, (label, commands)
        if label in ("boot", "rekey"):
            assert '["nix", "eval"' not in commands
    print("12 setup build, switch, selection, and rejection cases passed")
