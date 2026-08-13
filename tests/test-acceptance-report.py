#!/usr/bin/env python3

import json
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
WRITER = ROOT / "scripts" / "write-acceptance-report.py"

with tempfile.TemporaryDirectory() as directory:
    scratch = Path(directory)
    results = scratch / "results.tsv"
    output = scratch / "report.json"
    results.write_text("alpha\tpass\t0\t1250000000\nbeta\tfail\t7\t250000000\n")
    subprocess.run([
        str(WRITER), "--results", str(results), "--output", str(output),
        "--started-ns", "1000000000", "--ended-ns", "3000000000",
        "--status", "fail",
    ], cwd=ROOT, check=True)
    report = json.loads(output.read_text())
    assert report["schema"] == "swtos-emulator-acceptance/v1"
    assert report["status"] == "fail"
    assert report["duration_seconds"] == 2.0
    assert report["summary"] == {"total": 2, "passed": 1, "failed": 1}
    assert report["recipes"][1]["exit_code"] == 7
    assert len(report["tools"]["plsw"]["sha256"]) == 64

print("PASS: acceptance report records results, timing, revision, and tool identities")

