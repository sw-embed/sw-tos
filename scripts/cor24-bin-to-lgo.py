#!/usr/bin/env python3
"""Convert a flat COR24 binary into a complete, verified LGO image."""

from __future__ import annotations

import argparse
from pathlib import Path


def encode(data: bytes, load_address: int, entry_address: int, record_bytes: int) -> str:
    if not 1 <= record_bytes <= 255:
        raise ValueError("record size must be between 1 and 255 bytes")
    if not 0 <= load_address <= 0xFFFFFF or not 0 <= entry_address <= 0xFFFFFF:
        raise ValueError("load and entry addresses must fit in 24 bits")
    if load_address + len(data) > 0x1000000:
        raise ValueError("binary extends beyond the 24-bit address space")

    lines = []
    for offset in range(0, len(data), record_bytes):
        payload = data[offset : offset + record_bytes]
        lines.append(f"L{load_address + offset:06X}{payload.hex().upper()}")
    lines.append(f"G{entry_address:06X}")
    return "\n".join(lines) + "\n"


def verify(text: str, expected: bytes, load_address: int, entry_address: int) -> None:
    rebuilt = bytearray()
    next_address = load_address
    jump_records = []
    for line_number, line in enumerate(text.splitlines(), 1):
        if line.startswith("L"):
            if len(line) < 9 or (len(line) - 7) % 2:
                raise ValueError(f"line {line_number}: malformed L record")
            address = int(line[1:7], 16)
            if address != next_address:
                raise ValueError(
                    f"line {line_number}: expected address {next_address:06X}, got {address:06X}"
                )
            payload = bytes.fromhex(line[7:])
            if not payload:
                raise ValueError(f"line {line_number}: empty L record")
            rebuilt.extend(payload)
            next_address += len(payload)
        elif line.startswith("G") and len(line) == 7:
            jump_records.append(int(line[1:], 16))
        else:
            raise ValueError(f"line {line_number}: unsupported or malformed record")

    if bytes(rebuilt) != expected:
        raise ValueError("LGO data does not reproduce the input binary exactly")
    if jump_records != [entry_address]:
        raise ValueError(
            f"expected exactly one G{entry_address:06X} record, got {jump_records}"
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--load-address", type=lambda value: int(value, 0), default=0)
    parser.add_argument("--entry-address", type=lambda value: int(value, 0), default=0)
    parser.add_argument("--record-bytes", type=int, default=32)
    args = parser.parse_args()

    data = args.input.read_bytes()
    text = encode(data, args.load_address, args.entry_address, args.record_bytes)
    verify(text, data, args.load_address, args.entry_address)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(text, encoding="ascii")
    print(
        f"Complete LGO: {len(data)} bytes at {args.load_address:06X}, "
        f"entry {args.entry_address:06X} -> {args.output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
