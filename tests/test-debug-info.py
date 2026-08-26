#!/usr/bin/env python3

import binascii
import hashlib
import json
import pathlib
import sys


def main() -> int:
    directory = pathlib.Path(sys.argv[1])
    binary = (directory / "program.bin").read_bytes()
    debug = json.loads((directory / "program.debug.json").read_text())
    assert debug["format"] == "swtos-debug-v1"
    assert debug["image_size"] == len(binary)
    assert debug["image_sha256"] == hashlib.sha256(binary).hexdigest()
    expected_crc = binascii.crc32(binary[:debug["build_id_size"]]) & 0xFFFFFF
    assert debug["build_id"] == f"crc24:{expected_crc:06x}"
    symbols = {item["name"]: item["address"] for item in debug["symbols"]}
    assert symbols["_start"] == 0 and symbols["_proc_table"] == debug["build_id_size"]
    assert any(item["name"] == "_start" and item["end"] > 0 for item in debug["functions"])
    assert any(item["address"] == 0 and item["source"] == "kernel.s" for item in debug["instructions"])
    assert any(item["name"] == "_proc_table" for item in debug["variable_locations"])
    print("PASS: debug artifact binds symbols, code, source, variables, and image identity")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
