#!/usr/bin/env python3
"""Regression tests for interactive menu input filtering."""

import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "swtos_terminal", ROOT / "scripts" / "swtos-terminal.py"
)
assert SPEC is not None and SPEC.loader is not None
TERMINAL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TERMINAL)


def filter_bytes(data: bytes):
    prompt = True
    discard = False
    forwarded = []
    for value in data:
        value, discard = TERMINAL.filter_menu_input(value, prompt, discard)
        if value is not None:
            forwarded.append(value)
            prompt = False
    return bytes(forwarded), discard


assert filter_bytes(b"1\n") == (b"1", True)
assert filter_bytes(b"2\r\n") == (b"2", True)
assert filter_bytes(b"1\nx") == (b"1x", False)
assert filter_bytes(b"3\n\x1d") == (b"3\x1d", False)
print("PASS: menu line endings do not leak into resident apps")
