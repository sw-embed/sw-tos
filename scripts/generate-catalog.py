#!/usr/bin/env python3
"""Generate the SWTOS PL/SW resident catalog from TOML."""

import argparse
import binascii
import re
import sys
import tomllib
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_MANIFEST = ROOT / "catalog" / "catalog.toml"
DEFAULT_OUTPUT = ROOT / "include" / "catalog_generated.msw"
DEFAULT_SCHEDULED_OUTPUT = ROOT / "hal" / "cor24" / "catalog_generated.s"
NAME_PATTERN = re.compile(r"[a-z][a-z0-9-]*\Z")
ENTRY_PATTERN = re.compile(r"[A-Z_][A-Z0-9_]*\Z")
SCHEDULED_ENTRY_PATTERN = re.compile(r"_[A-Za-z_][A-Za-z0-9_]*\Z")
KINDS = {"program": "IMAGE_PROGRAM", "service": "IMAGE_SERVICE"}
FLAGS = {
    "resident": ("IMAGE_RESIDENT", 1),
    "single_instance": ("IMAGE_SINGLE_INST", 2),
    "privileged": ("IMAGE_PRIVILEGED", 4),
    "autostart": ("IMAGE_AUTOSTART", 8),
    "restartable": ("IMAGE_RESTARTABLE", 16),
    "read_only": ("IMAGE_READ_ONLY", 32),
}
ENTRY_KEYS = {"name", "entry", "scheduled_entry", "stack_words", "state_words", "flags", "image_manifest"}


def fail(message: str) -> None:
    raise ValueError(message)


def load_entries(path: Path) -> list[dict]:
    with path.open("rb") as stream:
        document = tomllib.load(stream)
    unknown_sections = set(document) - set(KINDS)
    if unknown_sections:
        fail(f"unknown manifest section: {sorted(unknown_sections)[0]}")

    entries = []
    names = set()
    for section, kind in KINDS.items():
        values = document.get(section, [])
        if not isinstance(values, list):
            fail(f"{section} must be an array of tables")
        for index, value in enumerate(values):
            label = f"{section}[{index}]"
            if not isinstance(value, dict):
                fail(f"{label} must be a table")
            unknown_keys = set(value) - ENTRY_KEYS
            if unknown_keys:
                fail(f"{label} has unknown key: {sorted(unknown_keys)[0]}")
            missing_keys = (ENTRY_KEYS - {"image_manifest"}) - set(value)
            if missing_keys:
                fail(f"{label} is missing: {sorted(missing_keys)[0]}")

            name = value["name"]
            entry = value["entry"]
            scheduled_entry = value["scheduled_entry"]
            stack_words = value["stack_words"]
            state_words = value["state_words"]
            flags = value["flags"]
            image_manifest = value.get("image_manifest")
            if not isinstance(name, str) or not NAME_PATTERN.fullmatch(name):
                fail(f"{label} has invalid name")
            if len(name.encode("ascii")) > 15:
                fail(f"{label} name exceeds block catalog record")
            if name in names:
                fail(f"duplicate catalog name: {name}")
            names.add(name)
            if not isinstance(entry, str) or not ENTRY_PATTERN.fullmatch(entry):
                fail(f"{label} has invalid entry symbol")
            if not isinstance(scheduled_entry, str) or not SCHEDULED_ENTRY_PATTERN.fullmatch(scheduled_entry):
                fail(f"{label} has invalid scheduled entry symbol")
            if not isinstance(stack_words, int) or isinstance(stack_words, bool) or stack_words <= 0:
                fail(f"{label} stack_words must be a positive integer")
            if not isinstance(state_words, int) or isinstance(state_words, bool) or state_words < 0:
                fail(f"{label} state_words must be a nonnegative integer")
            if not isinstance(flags, list) or not all(isinstance(flag, str) for flag in flags):
                fail(f"{label} flags must be an array of strings")
            unknown_flags = set(flags) - set(FLAGS)
            if unknown_flags:
                fail(f"{label} has unknown flag: {sorted(unknown_flags)[0]}")
            if len(flags) != len(set(flags)):
                fail(f"{label} has duplicate flags")
            if image_manifest is not None:
                if section != "program" or not isinstance(image_manifest, str) or not image_manifest.endswith(".toml"):
                    fail(f"{label} has invalid image_manifest")
                if "resident" in flags:
                    fail(f"{label} embedded image cannot be resident")
                image_path = (ROOT / image_manifest).resolve()
                if not image_path.is_relative_to(ROOT) or not image_path.is_file():
                    fail(f"{label} image_manifest does not exist in repository")
                with image_path.open("rb") as image_stream:
                    image_document = tomllib.load(image_stream)
                text_words = image_document.get("text_words")
                data_words = image_document.get("data_words")
                if (
                    not isinstance(text_words, int)
                    or isinstance(text_words, bool)
                    or text_words <= 0
                    or not isinstance(data_words, int)
                    or isinstance(data_words, bool)
                    or data_words < 0
                    or 9 + text_words + data_words > 0xFFFFFF
                ):
                    fail(f"{label} image_manifest has invalid word counts")
                image_words = 9 + text_words + data_words
            else:
                image_words = 0

            entries.append(
                {
                    "name": name,
                    "entry": entry,
                    "scheduled_entry": scheduled_entry,
                    "kind": kind,
                    "stack_words": stack_words,
                    "state_words": state_words,
                    "flags": flags,
                    "image_manifest": image_manifest,
                    "image_words": image_words,
                }
            )
    if not entries:
        fail("catalog must contain at least one program or service")
    return entries


def render(entries: list[dict], manifest: Path) -> str:
    lines = [
        "/* Generated by scripts/generate-catalog.py; do not edit. */",
        f"/* Source: {manifest.relative_to(ROOT)} */",
        "",
        "%DEFINE CATALOG_DESC_WORDS 8;",
        f"%DEFINE CATALOG_COUNT {len(entries)};",
        f"DCL CATALOG_TABLE({len(entries) * 8}) INT;",
        "",
    ]
    for index, entry in enumerate(entries):
        size = len(entry["name"]) + 1
        lines.append(f"DCL CATALOG_NAME_{index}({size}) CHAR INIT('{entry['name']}');")
    lines.extend(["", "CATALOG_INIT: PROC;", "    ASM DO;", "        'la      r2,_CATALOG_TABLE';"])
    for index, entry in enumerate(entries):
        flag_value = sum(FLAGS[flag][1] for flag in entry["flags"])
        kind_value = 0 if entry["kind"] == "IMAGE_PROGRAM" else 2
        values = (
            f"_CATALOG_NAME_{index}", kind_value, f"_{entry['entry']}",
            entry["image_words"], 0, entry["stack_words"],
            entry["state_words"], flag_value,
        )
        for word, value in enumerate(values):
            lines.append(f"        'la      r0,{value}';")
            lines.append(f"        'sw      r0,{word * 3}(r2)';")
        if index + 1 < len(entries):
            lines.append("        'add     r2,24';")
    lines.extend(["    END;", "END;", ""])
    return "\n".join(lines)


def render_scheduled(entries: list[dict], manifest: Path) -> str:
    lines = [
        "; Generated by scripts/generate-catalog.py; do not edit.",
        f"; Source: {manifest.relative_to(ROOT)}",
        "",
        "_scheduled_catalog_table:",
    ]
    for entry in entries:
        label = entry["name"].replace("-", "_")
        lines.append(f"        .word   _scheduled_{label}_descriptor")
    lines.append("        .word   0")
    lines.append("")
    for entry in entries:
        label = entry["name"].replace("-", "_")
        flag_value = sum(FLAGS[flag][1] for flag in entry["flags"])
        kind_value = 1 if entry["image_manifest"] else (0 if entry["kind"] == "IMAGE_PROGRAM" else 2)
        name_bytes = ",".join(str(byte) for byte in entry["name"].encode("ascii"))
        lines.extend(
            [
                f"_scheduled_{label}_descriptor:",
                f"        .word   _scheduled_{label}_name",
                f"        .word   {kind_value}",
                f"        .word   {entry['scheduled_entry']}",
                f"        .word   _embedded_{label}_image" if entry["image_manifest"] else "        .word   0",
                f"        .word   {entry['image_words']}",
                f"        .word   {entry['stack_words']}",
                f"        .word   {entry['state_words']}",
                f"        .word   {flag_value}",
                f"_scheduled_{label}_name:",
                f"        .byte   {name_bytes},0",
                "",
            ]
        )
    records = []
    for index, entry in enumerate(entries):
        name = entry["name"].encode("ascii") + b"\0"
        name_field = name + bytes(16 - len(name))
        record = name_field + bytes([index]) + bytes(7)
        records.append(record)
    record_bytes = b"".join(records)
    catalog_crc = binascii.crc32(record_bytes) & 0xFFFFFF
    header = bytes([len(entries), 1]) + b"SWT" + catalog_crc.to_bytes(3, "big")
    header_values = ",".join(str(value) for value in header)
    lines.extend(["_block_catalog_index:", f"        .byte   {header_values}"])
    for record in records:
        values = ",".join(str(value) for value in record)
        lines.append(f"        .byte   {values}")
    lines.extend(["_block_catalog_index_end:", ""])
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--scheduled-output", type=Path, default=DEFAULT_SCHEDULED_OUTPUT)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--list-images", action="store_true")
    args = parser.parse_args()
    try:
        entries = load_entries(args.manifest)
        if args.list_images:
            for entry in entries:
                if entry["image_manifest"] is not None:
                    print(f"{entry['name']}\t{entry['image_manifest']}")
            return 0
        rendered = render(entries, args.manifest)
        scheduled_rendered = render_scheduled(entries, args.manifest)
    except (OSError, tomllib.TOMLDecodeError, ValueError) as error:
        print(f"catalog generation failed: {error}", file=sys.stderr)
        return 1

    if args.check:
        try:
            current = args.output.read_text()
            scheduled_current = args.scheduled_output.read_text()
        except OSError as error:
            print(f"catalog check failed: {error}", file=sys.stderr)
            return 1
        if current != rendered or scheduled_current != scheduled_rendered:
            print("catalog check failed: regenerate catalog outputs", file=sys.stderr)
            return 1
        print(f"PASS: catalog is current ({len(load_entries(args.manifest))} entries)")
        return 0

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(rendered)
    args.scheduled_output.parent.mkdir(parents=True, exist_ok=True)
    args.scheduled_output.write_text(scheduled_rendered)
    print(f"Generated {len(entries)} entries -> {args.output}, {args.scheduled_output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
