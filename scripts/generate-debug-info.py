#!/usr/bin/env python3
"""Generate deterministic symbolic debug metadata for a linked COR24 image."""

import argparse
import binascii
import hashlib
import json
import pathlib
import re
import sys

MAP_LINE = re.compile(r"^(\S+)\s+([0-9A-Fa-f]{6})\s+(\S+)$")
LISTING_INSTRUCTION = re.compile(
    r"^([0-9A-Fa-f]{4,6}):\s+((?:[0-9A-Fa-f]{2}\s+)+)\s*(.*?)\s*$"
)


def parse_map(path: pathlib.Path):
    symbols = []
    for line in path.read_text().splitlines():
        match = MAP_LINE.match(line)
        if match:
            symbols.append(
                {
                    "name": match.group(1),
                    "address": int(match.group(2), 16),
                    "module": match.group(3),
                }
            )
    return sorted(symbols, key=lambda item: (item["address"], item["name"]))


def parse_listing(path: pathlib.Path, module: str):
    instructions = []
    source = f"{module}.s"
    for line_number, line in enumerate(path.read_text().splitlines(), 1):
        match = LISTING_INSTRUCTION.match(line)
        if not match:
            continue
        encoded = bytes.fromhex(match.group(2))
        instructions.append(
            {
                "address": int(match.group(1), 16),
                "size": len(encoded),
                "bytes": encoded.hex(),
                "text": match.group(3),
                "source": source,
                "line": line_number,
            }
        )
    return instructions


def generate(binary_path, map_path, listings):
    binary = binary_path.read_bytes()
    symbols = parse_map(map_path)
    symbol_addresses = {symbol["name"]: symbol["address"] for symbol in symbols}
    if "_proc_table" not in symbol_addresses:
        raise ValueError("linked map has no _proc_table executable boundary")
    build_id_size = symbol_addresses["_proc_table"]
    instructions = []
    for listing in listings:
        instructions.extend(parse_listing(listing, listing.stem))
    instructions.sort(key=lambda item: item["address"])

    instruction_addresses = {item["address"] for item in instructions}
    function_symbols = [
        symbol
        for symbol in symbols
        if symbol["address"] < build_id_size and symbol["address"] in instruction_addresses
    ]
    functions = []
    for index, symbol in enumerate(function_symbols):
        following = next(
            (item["address"] for item in function_symbols[index + 1 :] if item["address"] > symbol["address"]),
            build_id_size,
        )
        functions.append(
            {
                "name": symbol["name"],
                "address": symbol["address"],
                "end": following,
                "module": symbol["module"],
            }
        )

    crc24 = binascii.crc32(binary[:build_id_size]) & 0xFFFFFF
    return {
        "format": "swtos-debug-v1",
        "build_id": f"crc24:{crc24:06x}",
        "build_id_size": build_id_size,
        "image_sha256": hashlib.sha256(binary).hexdigest(),
        "image_size": len(binary),
        "symbols": symbols,
        "functions": functions,
        "instructions": instructions,
        "variable_locations": [
            {
                "name": symbol["name"],
                "address": symbol["address"],
                "encoding": "absolute-byte-address",
            }
            for symbol in symbols
            if symbol["address"] >= build_id_size or symbol["address"] not in instruction_addresses
        ],
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=pathlib.Path)
    parser.add_argument("--map", required=True, dest="map_path", type=pathlib.Path)
    parser.add_argument("--listing", action="append", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    document = generate(args.binary, args.map_path, args.listing)
    rendered = json.dumps(document, indent=2, sort_keys=True) + "\n"
    if args.check:
        if not args.output.exists() or args.output.read_text() != rendered:
            print("debug information is missing or stale", file=sys.stderr)
            return 1
        print(f"PASS: debug information matches {document['build_id']}")
        return 0
    args.output.write_text(rendered)
    print(f"Debug info: {args.output} ({document['build_id']})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
