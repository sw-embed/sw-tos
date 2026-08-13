#!/usr/bin/env python3
"""Validate emulator acceptance evidence for a hardware handoff bundle."""

import argparse
import json
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
RUNNER = ROOT / "scripts" / "emulator-acceptance.sh"


def command_output(command: list[str]) -> str:
    return subprocess.check_output(command, cwd=ROOT, text=True).strip()


def reject(message: str) -> int:
    print(f"Invalid emulator acceptance report: {message}", file=sys.stderr)
    return 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("report", type=Path)
    args = parser.parse_args()

    try:
        report = json.loads(args.report.read_text())
    except (OSError, json.JSONDecodeError) as error:
        return reject(str(error))

    expected_recipes = command_output([str(RUNNER), "--list"]).splitlines()
    current_commit = command_output(["git", "rev-parse", "HEAD"])
    current_branch = command_output(["git", "branch", "--show-current"])
    current_dirty = bool(command_output([
        "git", "status", "--porcelain", "--untracked-files=no"
    ]))

    if report.get("schema") != "swtos-emulator-acceptance/v1":
        return reject("unsupported schema")
    if report.get("status") != "pass":
        return reject("overall status is not pass")
    repository = report.get("repository", {})
    if repository.get("commit") != current_commit:
        return reject("report commit does not match HEAD")
    if repository.get("branch") != current_branch:
        return reject("report branch does not match the current branch")
    if repository.get("tracked_worktree_dirty") is not False:
        return reject("report was produced from a dirty tracked worktree")
    if current_dirty:
        return reject("current tracked worktree is dirty")

    recipes = report.get("recipes", [])
    names = [item.get("name") for item in recipes]
    if names != expected_recipes:
        return reject("recipe manifest does not match the current acceptance gate")
    if any(item.get("status") != "pass" or item.get("exit_code") != 0
           for item in recipes):
        return reject("one or more recipe results did not pass")
    summary = report.get("summary", {})
    if summary != {"total": len(expected_recipes),
                   "passed": len(expected_recipes), "failed": 0}:
        return reject("summary does not match recipe results")

    print(
        f"PASS: acceptance report matches {current_commit[:7]} "
        f"with {len(expected_recipes)} passing recipes"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

