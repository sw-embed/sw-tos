#!/usr/bin/env python3
"""Verify the PL/SW process descriptor matches the COR24 ABI manifest."""

import re
import sys
import tomllib
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "hal" / "cor24" / "proc-desc.toml"
PLSW = ROOT / "include" / "swtos.msw"
FIELD_NAMES = {
    "regs0": "PROC_REGS0_OFFSET",
    "regs1": "PROC_REGS1_OFFSET",
    "regs2": "PROC_REGS2_OFFSET",
    "sp": "PROC_SP_OFFSET",
    "pc": "PROC_PC_OFFSET",
    "status": "PROC_STATUS_OFFSET",
    "endpoint": "PROC_ENDPOINT_OFFSET",
    "sender": "PROC_SENDER_OFFSET",
    "state": "PROC_STATE_OFFSET",
    "priority": "PROC_PRIORITY_OFFSET",
    "quantum": "PROC_QUANTUM_OFFSET",
    "msgptr": "PROC_MSGPTR_OFFSET",
    "stateptr": "PROC_STATEPTR_OFFSET",
}


def main() -> int:
    abi = tomllib.loads(MANIFEST.read_text())
    source = PLSW.read_text()
    expected = dict(abi["fields"])
    expected["size"] = abi["size"]
    symbols = FIELD_NAMES | {"size": "PROC_DESC_SIZE"}
    for field, value in expected.items():
        symbol = symbols[field]
        match = re.search(rf"%DEFINE\s+{symbol}\s+(\d+);", source)
        if match is None:
            print(f"process ABI error: {symbol} is missing", file=sys.stderr)
            return 1
        actual = int(match.group(1))
        if actual != value:
            print(
                f"process ABI error: {symbol} is {actual}; expected {value}",
                file=sys.stderr,
            )
            return 1
    offsets = list(abi["fields"].values())
    if offsets != list(range(0, abi["size"], 3)):
        print("process ABI error: fields must densely cover 3-byte words", file=sys.stderr)
        return 1
    print("PASS: PL/SW and COR24 process descriptors share 13 words (39 bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
