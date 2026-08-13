#!/usr/bin/env python3

import copy
import json
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
VALIDATOR = ROOT / "scripts" / "validate-acceptance-report.py"
SOURCE = ROOT / "build" / "emulator-acceptance" / "report.json"


def validate(report: dict, path: Path, expected: bool) -> None:
    path.write_text(json.dumps(report))
    result = subprocess.run(
        [str(VALIDATOR), str(path)], cwd=ROOT, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT
    )
    assert (result.returncode == 0) is expected, result.stdout


source = json.loads(SOURCE.read_text())
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "report.json"
    validate(source, path, True)

    stale = copy.deepcopy(source)
    stale["repository"]["commit"] = "0" * 40
    validate(stale, path, False)

    dirty = copy.deepcopy(source)
    dirty["repository"]["tracked_worktree_dirty"] = True
    validate(dirty, path, False)

    failed = copy.deepcopy(source)
    failed["status"] = "fail"
    validate(failed, path, False)

    incomplete = copy.deepcopy(source)
    incomplete["recipes"].pop()
    validate(incomplete, path, False)

print("PASS: hardware bundle rejects stale, dirty, failed, and incomplete acceptance evidence")

