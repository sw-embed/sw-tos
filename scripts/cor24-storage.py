#!/usr/bin/env python3
"""Build and validate a block-aligned SWTOS program storage image."""

import argparse
import binascii
import importlib.util
import sys
import tomllib
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
BLOCK_BYTES = 8
HEADER_BYTES = 8
RECORD_BYTES = 24
NAME_BYTES = 16
FLAG_HAS_IMAGE = 1


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


catalog_tool = load_module("swtos_catalog", ROOT / "scripts" / "generate-catalog.py")
image_tool = load_module("swtos_image", ROOT / "scripts" / "cor24-image.py")


def u24(value: int) -> bytes:
    if not 0 <= value <= 0xFFFFFF:
        raise ValueError("storage offset or length exceeds 24-bit range")
    return value.to_bytes(3, "big")


def align(value: int, boundary: int = BLOCK_BYTES) -> int:
    return (value + boundary - 1) // boundary * boundary


def build_storage(manifest_path: Path, image_alignment: int = BLOCK_BYTES) -> bytes:
    entries = catalog_tool.load_entries(manifest_path)
    cursor = align(HEADER_BYTES + len(entries) * RECORD_BYTES, image_alignment)
    records = []
    images = []
    for ordinal, entry in enumerate(entries):
        name = entry["name"].encode("ascii") + b"\0"
        name_field = name + bytes(NAME_BYTES - len(name))
        if entry["image_manifest"] is None:
            image_offset = 0
            image = b""
            flags = 0
        else:
            image_manifest = ROOT / entry["image_manifest"]
            image = image_tool.build_image(image_tool.load_manifest(image_manifest))
            image_tool.validate_image(image)
            image_offset = cursor
            flags = FLAG_HAS_IMAGE
            cursor += align(len(image))
            cursor = align(cursor, image_alignment)
        records.append(
            name_field + bytes([ordinal]) + u24(image_offset) + u24(len(image)) + bytes([flags])
        )
        images.append((image_offset, image))

    record_bytes = b"".join(records)
    catalog_crc = binascii.crc32(record_bytes) & 0xFFFFFF
    header = bytes([len(entries), 1]) + b"SWT" + catalog_crc.to_bytes(3, "big")
    output = bytearray(header)
    output.extend(record_bytes)
    output.extend(bytes(align(len(output)) - len(output)))
    for image_offset, image in images:
        if not image:
            continue
        if len(output) > image_offset:
            raise ValueError("internal storage layout error")
        output.extend(bytes(image_offset - len(output)))
        output.extend(image)
        output.extend(bytes(align(len(output)) - len(output)))
    return bytes(output)


def validate_storage(data: bytes) -> dict:
    if len(data) < HEADER_BYTES or len(data) % BLOCK_BYTES:
        raise ValueError("storage image is not a complete set of eight-byte blocks")
    count = data[0]
    if data[1] != 1 or data[2:5] != b"SWT":
        raise ValueError("storage catalog header version or magic is invalid")
    index_end = HEADER_BYTES + count * RECORD_BYTES
    if index_end > len(data):
        raise ValueError("storage catalog is truncated")
    expected_crc = int.from_bytes(data[5:8], "big")
    if binascii.crc32(data[HEADER_BYTES:index_end]) & 0xFFFFFF != expected_crc:
        raise ValueError("storage catalog checksum mismatch")
    names = set()
    image_count = 0
    for ordinal in range(count):
        start = HEADER_BYTES + ordinal * RECORD_BYTES
        record = data[start : start + RECORD_BYTES]
        raw_name = record[:NAME_BYTES]
        if b"\0" not in raw_name:
            raise ValueError("catalog name is not NUL terminated")
        name = raw_name.split(b"\0", 1)[0].decode("ascii")
        if not name or name in names:
            raise ValueError("catalog name is empty or duplicated")
        names.add(name)
        if record[NAME_BYTES] != ordinal:
            raise ValueError("catalog ordinal does not match record position")
        offset = int.from_bytes(record[17:20], "big")
        length = int.from_bytes(record[20:23], "big")
        flags = record[23]
        if flags & ~FLAG_HAS_IMAGE:
            raise ValueError("catalog record has unknown flags")
        if flags & FLAG_HAS_IMAGE:
            if offset < align(index_end) or offset % BLOCK_BYTES or length == 0:
                raise ValueError("catalog image has invalid offset or length")
            if offset + length > len(data):
                raise ValueError("catalog image extends beyond storage")
            image_tool.validate_image(data[offset : offset + length])
            image_count += 1
        elif offset != 0 or length != 0:
            raise ValueError("catalog record without an image has storage extent")
    return {"entries": count, "images": image_count, "blocks": len(data) // BLOCK_BYTES}


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    build_parser = subparsers.add_parser("build")
    build_parser.add_argument("output", type=Path)
    build_parser.add_argument("--manifest", type=Path, default=ROOT / "catalog" / "catalog.toml")
    build_parser.add_argument("--image-alignment", type=int, default=BLOCK_BYTES)
    build_parser.add_argument("--check", action="store_true")
    validate_parser = subparsers.add_parser("validate")
    validate_parser.add_argument("image", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "build":
            if args.image_alignment < BLOCK_BYTES or args.image_alignment % BLOCK_BYTES:
                raise ValueError("image alignment must be a positive multiple of eight")
            expected = build_storage(args.manifest.resolve(), args.image_alignment)
            validate_storage(expected)
            if args.check:
                if args.output.read_bytes() != expected:
                    raise ValueError("generated storage image is missing or stale")
                print(f"PASS: storage image is current ({len(expected) // BLOCK_BYTES} blocks)")
            else:
                args.output.parent.mkdir(parents=True, exist_ok=True)
                args.output.write_bytes(expected)
                print(f"Built storage: {len(expected) // BLOCK_BYTES} blocks -> {args.output}")
        else:
            result = validate_storage(args.image.read_bytes())
            print(
                f"PASS: storage image valid ({result['entries']} entries, "
                f"{result['images']} images, {result['blocks']} blocks)"
            )
    except (OSError, UnicodeError, tomllib.TOMLDecodeError, ValueError) as error:
        print(f"COR24 storage error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
