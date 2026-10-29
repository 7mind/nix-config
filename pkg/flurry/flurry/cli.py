from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Sequence

from .git import Git
from .nix import Nix
from .permissions import Permissions
from .process import FlurryError, Runner, redact
from .pull import Pull
from .state import workspace_lock
from .sync import Sync, SyncOptions, plan_sync
from .workspace import build_graph, discover, init_config, load_config


COMMAND_TIMEOUT = 900.0


def _common(parser: argparse.ArgumentParser, suppress: bool) -> None:
    default = argparse.SUPPRESS
    parser.add_argument("--root", type=Path, default=default if suppress else Path.cwd(), help="Workspace directory (default: current directory)")
    parser.add_argument("--exclude", dest="exclude" if suppress else "global_excludes", action="append", default=default if suppress else [], metavar="PATTERN", help="Add a workspace-relative exclusion; repeatable")
    parser.add_argument("--json", action="store_true", default=default if suppress else False, help="Machine-readable output")
    parser.add_argument("--timeout", type=float, default=default if suppress else COMMAND_TIMEOUT, help="Timeout per Git/Nix/API command, in seconds")


def _sync_options(parser: argparse.ArgumentParser) -> None:
    policy = parser.add_mutually_exclusive_group()
    policy.add_argument("--preserve", "--without-committing", action="store_true", help="Keep existing edits local; generated lock commits are still published")
    policy.add_argument("--commit", choices=("staged", "all"), metavar="{staged,all}", help="Commit this explicit scope of existing edits before synchronization")
    parser.add_argument("--message", metavar="MESSAGE", help="Required message for --commit")
    parser.add_argument("--check", choices=("eval", "full", "none"), default="eval", help="Validation before publication (default: eval)")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(prog="flurry", description="A little swarm of flakes: dependency-ordered Nix workspace maintenance.")
    _common(result, False)
    result.set_defaults(exclude=[])
    commands = result.add_subparsers(dest="command", required=True)
    for name, description in (
        ("init", "Create a default local workspace configuration without overwriting"),
        ("status", "Inspect sibling checkouts without fetching"),
        ("graph", "Show provider-to-consumer dependencies"),
        ("plan", "Preview synchronization; no fetch, commit or push"),
        ("sync", "Rebase and publish work and generated locks in dependency order"),
        ("pull", "Clone writable transitive dependencies at branch tips"),
        ("resume", "Revalidate and retry an interrupted synchronization"),
    ):
        command = commands.add_parser(name, help=description, description=description)
        _common(command, True)
        if name in ("sync", "plan"):
            _sync_options(command)
        if name == "sync":
            command.add_argument("--dry-run", action="store_true", help="Offline plan only, same as plan")
        if name == "pull":
            command.add_argument("flake", help="Local checkout, configured name or explicit flake reference")
            command.add_argument("--dry-run", action="store_true", help="Discover and check access, without cloning")
        if name == "resume":
            command.add_argument("run_id", help="Run ID from .flurry/runs/")
    return result


def _options(args: argparse.Namespace, excludes: tuple[str, ...]) -> SyncOptions:
    mode = "commit" if args.commit is not None else "preserve" if args.preserve else "reject"
    if args.message is not None and args.commit is None:
        raise FlurryError("--message requires --commit {staged,all}")
    return SyncOptions(mode, args.commit, args.message, args.check, excludes)


def _print(data: object) -> None:
    print(json.dumps(data, indent=2, sort_keys=True))


def execute(args: argparse.Namespace) -> int:
    if args.timeout <= 0:
        raise FlurryError("--timeout must be positive")
    excludes = tuple(args.global_excludes + args.exclude)
    if args.command == "init":
        path = init_config(args.root, excludes)
        if args.json:
            _print({"path": str(path)})
        else:
            print(f"Created {path}")
        return 0
    config = load_config(args.root, excludes)
    runner = Runner(os.environ, args.timeout)
    nix = Nix(runner)
    report = lambda message: print(message, file=sys.stderr)
    if args.command == "status":
        repositories = discover(config, runner)
        rows = [{
            "name": repo.name, "path": str(repo.path), "branch": repo.branch,
            "head": repo.head, "upstream": repo.upstream,
            "origin": redact(repo.origin) if repo.origin is not None else None,
            "excluded": repo.excluded,
            "changes": runner.git_text(repo.path, "status", "--porcelain=v1", "--untracked-files=all"),
            "common_dir": str(repo.common_dir),
        } for repo in repositories]
        if args.json:
            _print({"repositories": rows, "remote_freshness": "not fetched"})
        else:
            print("Local state only; remotes not fetched.")
            for row in rows:
                state = "excluded" if row["excluded"] else "dirty" if row["changes"] else "clean"
                print(f"{row['name']}: {row['branch'] or 'DETACHED'} [{state}]")
                if row["changes"]:
                    print(row["changes"])
        return 0
    if args.command == "graph":
        graph = build_graph(discover(config, runner), nix)
        rows = [{"provider": edge.provider.name, "consumer": edge.consumer.name,
                 "input": edge.input.name, "excluded": edge.provider.excluded,
                 "fixed": edge.input.source.rev is not None} for edge in graph.edges]
        order = [repo.name for repo in graph.order]
        if args.json:
            _print({"order": order, "edges": rows})
        else:
            for row in rows:
                boundary = " [excluded]" if row["excluded"] else " [fixed revision]" if row["fixed"] else ""
                print(f"{row['provider']} -> {row['consumer']} ({row['input']}){boundary}")
            print("Publication order: " + " -> ".join(order))
        return 0
    if args.command in ("plan", "sync"):
        options = _options(args, config.excludes)
        if args.command == "plan" or args.dry_run:
            plan = plan_sync(config, runner, nix, options)
            if args.json:
                _print(plan.to_dict())
            else:
                print(plan.to_dict()["notice"])
                for target in plan.targets:
                    print(f"{target.repository.name}: rebase on {target.remote}/{target.baseline.removeprefix('refs/heads/')}; push {target.push_remote}/{target.push_ref}")
                    changes = runner.git_text(target.repository.path, "status", "--porcelain=v1", "--untracked-files=all")
                    if changes:
                        print(changes)
                print(f"Existing edits: {options.dirty_mode}; generated locks: commit and publish; checks: {options.check_mode}")
            return 0
        if args.check == "none":
            report("Validation disabled explicitly (--check none).")
        journal = Sync(runner, nix, Git(runner), report).run(config, options, None)
        if args.json:
            _print(journal.document)
        else:
            print(f"Published selected flakes and lock updates. Run: {journal.path}")
        return 0
    if args.command == "resume":
        journal = Sync(runner, nix, Git(runner), report).resume(config, args.run_id)
        if args.json:
            _print(journal.document)
        else:
            print(f"Completed. Run: {journal.path}")
        return 0
    if args.command == "pull":
        reference = args.flake
        mappings: dict[str, str] = {}
        for settings in config.repositories:
            if settings.name == reference:
                if settings.path.exists():
                    reference = str(settings.path)
                elif settings.source is not None:
                    reference = settings.source.url
                else:
                    raise FlurryError(f"{settings.name}: missing checkout and no configured source")
            if settings.source is not None:
                mappings[settings.source.repository_id] = str(settings.path.relative_to(config.root))
        service = Pull(runner, nix, Permissions(runner, config.gitlab_hosts))
        if args.dry_run:
            plan = service.plan(reference, config.root, config.excludes, mappings)
            data = plan.to_dict()
            if not plan.complete:
                _print(data)
                return 1
        else:
            with workspace_lock(config.root):
                plan = service.plan(reference, config.root, config.excludes, mappings)
                results = service.apply(plan)
                data = {"plan": plan.to_dict(), "results": [item.to_dict() for item in results]}
        _print(data)
        return 0
    raise FlurryError("Unknown command")


def main(argv: Sequence[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        return execute(args)
    except (FlurryError, OSError, ValueError) as error:
        print(f"flurry: {redact(str(error))}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("flurry: interrupted; inspect retained run/recovery data before retrying", file=sys.stderr)
        return 130
