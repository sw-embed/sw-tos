#!/usr/bin/env python3

import importlib.util
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "cor24-bin-to-lgo.py"
spec = importlib.util.spec_from_file_location("cor24_bin_to_lgo", SCRIPT)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

payload = bytes(range(32)) + bytes(32) + bytes(range(32, 79))
text = module.encode(payload, 0x120, 0x123, 32)
module.verify(text, payload, 0x120, 0x123)

lines = text.splitlines()
assert lines[-1] == "G000123"
assert len([line for line in lines if line.startswith("G")]) == 1
assert any(line.startswith("L000140") and set(line[7:]) == {"0"} for line in lines)

for broken in (
    "\n".join(lines[:-1]) + "\n",
    text + "G000123\n",
    text.replace("L000140", "L000141", 1),
):
    try:
        module.verify(broken, payload, 0x120, 0x123)
    except ValueError:
        pass
    else:
        raise AssertionError("malformed or incomplete LGO passed verification")

with tempfile.TemporaryDirectory() as directory:
    output = Path(directory) / "image.lgo"
    output.write_text(text, encoding="ascii")
    module.verify(output.read_text(encoding="ascii"), payload, 0x120, 0x123)

print("PASS: complete LGO preserves zeros, addresses, payload, and one entry record")
