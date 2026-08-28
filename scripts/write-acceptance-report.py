#!/usr/bin/env python3
"""Write a reproducible JSON summary for the sequential emulator gate."""

import argparse
import hashlib
import json
import platform
import subprocess
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def command_output(command: list[str]) -> str:
    result = subprocess.run(
        command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, check=False
    )
    return result.stdout.strip()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tool_record(relative_path: str, version_args: list[str] | None = None) -> dict:
    path = ROOT / relative_path
    record = {"path": relative_path, "sha256": sha256(path)}
    if version_args is not None:
        record["version"] = command_output([str(path), *version_args])
    return record


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--results", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--started-ns", required=True, type=int)
    parser.add_argument("--ended-ns", required=True, type=int)
    parser.add_argument("--status", required=True, choices=("pass", "fail"))
    args = parser.parse_args()

    recipes = []
    for line in args.results.read_text().splitlines():
        name, status, exit_code, duration_ns = line.split("\t")
        recipes.append({
            "name": name,
            "status": status,
            "exit_code": int(exit_code),
            "duration_seconds": round(int(duration_ns) / 1_000_000_000, 3),
        })

    commit = command_output(["git", "rev-parse", "HEAD"])
    branch = command_output(["git", "branch", "--show-current"])
    dirty = bool(command_output(["git", "status", "--porcelain", "--untracked-files=no"]))
    report = {
        "schema": "swtos-emulator-acceptance/v1",
        "status": args.status,
        "started_at": datetime.fromtimestamp(
            args.started_ns / 1_000_000_000, timezone.utc
        ).isoformat(),
        "ended_at": datetime.fromtimestamp(
            args.ended_ns / 1_000_000_000, timezone.utc
        ).isoformat(),
        "duration_seconds": round(
            (args.ended_ns - args.started_ns) / 1_000_000_000, 3
        ),
        "repository": {
            "commit": commit,
            "branch": branch,
            "tracked_worktree_dirty": dirty,
        },
        "host": {
            "platform": platform.platform(),
            "python": platform.python_version(),
        },
        "tools": {
            "just": command_output(["just", "--version"]),
            "git": command_output(["git", "--version"]),
            "cor24_emu": tool_record("scripts/swtos-emu", ["--version"]),
            "cor24_asm": tool_record("tools/bin/cor24-asm", ["--version"]),
            "meta_gen": tool_record("tools/bin/meta-gen"),
            "link24": tool_record("tools/bin/link24"),
            "plsw": tool_record("tools/plsw.lgo"),
        },
        "summary": {
            "total": len(recipes),
            "passed": sum(item["status"] == "pass" for item in recipes),
            "failed": sum(item["status"] == "fail" for item in recipes),
        },
        "recipes": recipes,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Acceptance report: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

