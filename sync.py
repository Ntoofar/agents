#!/usr/bin/env python3
"""Plan or create selected skill links; never download, overwrite, or prune."""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath


class Invalid(ValueError):
    pass


def load(root, name):
    data = json.loads((root / name).read_text())
    if not isinstance(data, dict) or data.get("version") != 1:
        raise Invalid(f"{name}: expected version 1 object")
    return data


def relative(value, prefix):
    if not isinstance(value, str):
        raise Invalid("Expected a repository-relative path")
    path = PurePosixPath(value)
    if (path.is_absolute() or ".." in path.parts or len(path.parts) < 2
            or path.parts[0] != prefix):
        raise Invalid(f"Invalid {prefix} path: {value}")
    return path


def git(directory, *args):
    result = subprocess.run(
        ["git", "-C", str(directory), *args], capture_output=True, text=True
    )
    if result.returncode:
        # Git diagnostics may include private URLs; do not print them.
        raise Invalid(f"Cannot inspect vendor repository: {directory.name}")
    return result.stdout.strip()


def sources(root):
    data = load(root, "sources.json")
    repositories = data.get("repositories")
    if not isinstance(repositories, list) or not isinstance(data.get("imports"), list):
        raise Invalid("sources.json: repositories and imports must be lists")
    records = {}
    for record in repositories:
        if not isinstance(record, dict):
            raise Invalid("Invalid vendor source record")
        path = relative(record.get("path"), "vendor")
        if len(path.parts) != 2 or str(path) in records:
            raise Invalid("Vendor sources need unique vendor/<name> paths")
        if not isinstance(record.get("repository"), str) or not record["repository"]:
            raise Invalid(f"Missing repository URL for {path}")
        revision = record.get("revision")
        if not isinstance(revision, str) or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", revision):
            raise Invalid(f"Full commit SHA required for {path}")
        records[str(path)] = record
    return records


def check_vendor(root, source, records, checked):
    key = str(PurePosixPath(*source.relative_to(root).parts[:2]))
    if key not in records:
        raise Invalid(f"No locked source record for {key}")
    if key in checked:
        return
    directory = root / key
    record = records[key]
    if Path(git(directory, "rev-parse", "--show-toplevel")).resolve() != directory:
        raise Invalid(f"{key} must be an initialized separate Git repository")
    if git(directory, "rev-parse", "HEAD") != record["revision"]:
        raise Invalid(f"{key} does not match its locked revision")
    if git(directory, "config", "--get", "remote.origin.url") != record["repository"]:
        raise Invalid(f"{key} origin does not match sources.json")
    if git(directory, "status", "--porcelain", "--untracked-files=all"):
        raise Invalid(f"{key} has local changes; review before distributing skills")
    checked.add(key)


def destination(value, home):
    if not isinstance(value, str) or not value.startswith("~/"):
        raise Invalid("Agent destination must start with ~/ and stay inside home")
    path = PurePosixPath(value[2:])
    if path.is_absolute() or ".." in path.parts or not path.parts:
        raise Invalid("Invalid home destination")
    return home.joinpath(*path.parts)


def preflight(target, source, home):
    # Refuse redirected discovery roots and non-directory parent components.
    for parent in [target.parent, *target.parent.parents]:
        if parent == home:
            break
        if parent.is_symlink() or (parent.exists() and not parent.is_dir()):
            raise Invalid(f"Discovery parent must be a regular directory: {parent}")
    if target.is_symlink():
        if target.resolve() == source:
            return "keep"
        raise Invalid(f"Conflicting symlink: {target}")
    if target.exists():
        raise Invalid(f"Refusing to overwrite existing entry: {target}")
    return "link"


def plan(root, home, selected):
    agents = load(root, "manifest.json").get("agents")
    if not isinstance(agents, dict):
        raise Invalid("manifest.json: agents must be an object")
    if selected and not set(selected).issubset(agents):
        raise Invalid("Unknown agent selection")
    records = sources(root)
    checked = set()
    targets = set()
    entries = []
    for name, config in agents.items():
        if selected and name not in selected:
            continue
        if not isinstance(config, dict) or not isinstance(config.get("skills"), list):
            raise Invalid(f"Invalid agent configuration: {name}")
        if config.get("destination") is None:
            if config["skills"]:
                raise Invalid(f"Configure a discovery destination before selecting skills for {name}")
            continue
        directory = destination(config["destination"], home)
        for value in config["skills"]:
            prefix = "vendor" if isinstance(value, str) and value.startswith("vendor/") else "skills"
            path = relative(value, prefix)
            if prefix == "skills" and len(path.parts) != 2:
                raise Invalid("Custom skills must use skills/<name> paths")
            source = (root / str(path)).resolve()
            if not source.is_relative_to(root) or not (source / "SKILL.md").is_file():
                raise Invalid(f"Missing or out-of-repository SKILL.md: {path}")
            actual = source.relative_to(root)
            if actual.parts[0] == "vendor":
                check_vendor(root, source, records, checked)
            elif actual.parts[0] != "skills" or prefix == "vendor":
                raise Invalid(f"Skill must reside inside skills/ or a locked vendor: {path}")
            skill_name = path.name
            if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", skill_name):
                raise Invalid(f"Invalid skill directory name: {skill_name}")
            if name == "claude-code" and skill_name in {"synced", "anthropic-skills"}:
                raise Invalid(f"Reserved Claude Code skill name: {skill_name}")
            target = directory / skill_name
            if target in targets:
                raise Invalid(f"Duplicate skill destination: {target}")
            targets.add(target)
            entries.append((preflight(target, source, home), target, source))
    for target in targets:
        if any(parent in targets for parent in target.parents):
            raise Invalid("A selected skill overlaps another discovery directory")
    return entries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="Create links after complete preflight")
    parser.add_argument("--agent", action="append", help="Select one agent; repeat to select several")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    home = Path.home().resolve()
    try:
        entries = plan(root, home, args.agent)
        for action, target, source in entries:
            print(f"{action}: {target} -> {source}")
        if args.apply:
            for _, target, source in entries:
                if preflight(target, source, home) == "link":
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.symlink_to(source, target_is_directory=True)
        print(f"{'Synced' if args.apply else 'Planned'} {len(entries)} skill links.")
    except (Invalid, OSError, ValueError) as error:
        print(f"sync: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
