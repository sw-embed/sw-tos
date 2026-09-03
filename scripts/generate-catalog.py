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
DEFAULT_SHELL_OUTPUT = ROOT / "include" / "shell_catalog_generated.msw"
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
    # Explicit certification that every possible continuation remains inside
    # the private live image. The loader, not mere private allocation, uses
    # this bit to permit ADD-runway forced preemption.
    "preemptible_leaf": ("IMAGE_PREEMPTIBLE_LEAF", 64),
}
ENTRY_KEYS = {"name", "entry", "scheduled_entry", "stack_words", "state_words", "flags", "image_manifest"}

#: Catalog entry the shell fill demo spawns to load the scheduler. The name is
#: always emitted, including for manifests without such an entry: the demo
#: looks it up at run time and simply spawns no hogs when it is absent.
HOG_NAME = "cpu-hog"

#: Catalog entry the shell starts for itself at boot, so the monitor is present
#: from the first frame and is restartable by name after being killed.
MON_NAME = "mon"


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
                if "preemptible_leaf" in flags and image_document.get("relocation_count") != 0:
                    fail(f"{label} preemptible_leaf image must have zero relocations")
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
                if "preemptible_leaf" in flags:
                    fail(f"{label} preemptible_leaf must use a private image")
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
    lines.extend(
        [
            "_block_catalog_index_end:",
            "; Mutable authentication workspace sized to the complete generated record region.",
            "_block_catalog_buffer:",
            f"        .zero   {len(record_bytes)}",
            "",
        ]
    )
    images = [entry for entry in entries if entry["image_manifest"] is not None]
    image_bytes = sum(entry["image_words"] * 3 for entry in images)
    shell_strings = {
        "SHELL_DF_TEXT": f"catalog entries={len(entries)} images={len(images)} bytes={image_bytes}",
        "SHELL_HELP_1": "help ls dir ps run bg sync kill reboot",
        "SHELL_HELP_2": "df du mem stat uname",
        "SHELL_UNAME_TEXT": "SWTOS COR24 0.1",
        "SHELL_CPU_HOG_NAME": HOG_NAME,
        "SHELL_STAT_KIND": " kind=",
        "SHELL_STAT_SOURCE": " source=",
        "SHELL_STAT_STACK": " stack=",
        "SHELL_STAT_STATE": " state=",
        "SHELL_STAT_FLAGS": " flags=",
        "SHELL_STAT_IMAGE": " image=",
        "SHELL_PROGRAM_TEXT": "program",
        "SHELL_SERVICE_TEXT": "service",
        "SHELL_RESIDENT_TEXT": "resident",
        "SHELL_EMBEDDED_TEXT": "embedded",
        "SHELL_MEM_TOTAL": "total=",
        "SHELL_MEM_IMAGE": " image=",
        "SHELL_MEM_ARENA": " arena=",
        "SHELL_MEM_PEAK": " peak=",
        "SHELL_MEM_KSTACK": " kstack=",
        "SHELL_MEM_FREE": " free=",
        "SHELL_MEM_FAIL": " failures=",
        "SHELL_MEM_SLOTS": " slots=",
        "SHELL_MEM_RESET_TEXT": "mem counters reset",
        "SHELL_MEM_EP": "ep=",
        "SHELL_MEM_STATUS": " status=",
        "SHELL_MEM_PROC_STACK": " stack=",
        "SHELL_MEM_PROC_STATE": " state=",
        "SHELL_MEM_PROC_TOTAL": " total=",
        "SHELL_PROC_EP": "ep=",
        "SHELL_PROC_NAME": " name=",
        "SHELL_PROC_STATUS": " state=",
        "SHELL_PROC_BLOCKED": " blocked=",
        "SHELL_PROC_STACK": " stack=",
        "SHELL_PROC_STATE_WORDS": " statew=",
        "SHELL_PROC_DISPATCH": " dispatch=",
        "SHELL_PROC_YIELDS": " yields=",
        "SHELL_PROC_IPC": " ipc=",
        "SHELL_PROC_TTY_IN": " ttyin=",
        "SHELL_PROC_TTY_OUT": " ttyout=",
        "SHELL_PROC_NONE": "none",
        "SHELL_MON_STK": "stk ",
        "SHELL_MON_HEAP": "B heap ",
        "SHELL_MON_KSTK": "B kstk=",
        "SHELL_MON_FAIL": "B fail=",
        "SHELL_MON_EP": " ep=",
        "SHELL_MON_STATE": " s=",
        "SHELL_MON_BLOCKED": " b=",
        "SHELL_MON_ALLOC": " alloc=",
        "SHELL_MON_DISPATCH": "w d=",
        "SHELL_MON_YIELDS": " y=",
        "SHELL_MON_IO": " io=",
        "SHELL_TOPIC_HELP": "help NAME explains one command",
        "SHELL_TOPIC_LS": "ls and dir list the catalog",
        "SHELL_TOPIC_DF": "df shows catalog totals",
        "SHELL_TOPIC_DU": "du shows image sizes",
        "SHELL_TOPIC_PS": "ps lists processes, ps -l in detail",
        "SHELL_TOPIC_RUN": "run NAME starts a program in its own pane",
        "SHELL_TOPIC_BG": "bg NAME is run, and the prompt stays free",
        "SHELL_TOPIC_KILL": "kill EP ends a process, ep=N accepted too",
        "SHELL_TOPIC_MEM": "mem totals, mem -r resets, mem -p per process",
        "SHELL_TOPIC_STAT": "stat NAME or stat EP describes one",
        "SHELL_TOPIC_UNAME": "uname shows the system name and version",
        "SHELL_TOPIC_BOOT": "reboot ends apps and restarts shell",
        "SHELL_PROC_FORCED": " fp=",
        "SHELL_PROC_CPU": " cpu=",
        "SHELL_MON_NAME": MON_NAME,
        "SHELL_SYNC_NOTE": "no free slot: running it here",
        "SHELL_FG_HINT": "[Ctrl-[ to end]",
        "SHELL_KILL_NO_SUCH": "no such endpoint",
        "SHELL_KILL_GONE": "nothing is running there",
        "SHELL_KILL_USAGE": "kill needs an endpoint, as in kill 3 or kill ep=3",
        "SHELL_SYNC_NEEDS_SLOT": "needs a slot of its own",
        "SHELL_TOPIC_SYNC": "sync NAME runs it here, without a slot",
    }
    for index, entry in enumerate(images):
        shell_strings[f"SHELL_DU_TEXT_{index}"] = f"{entry['name']} {entry['image_words'] * 3} bytes"
    # Names the shell starts for itself; the PL/SW side declares them, the
    # storage lives here with every other shell string.
    startup = [
        entry for entry in entries
        if entry["kind"] == "IMAGE_PROGRAM" and "autostart" in entry["flags"]
    ]
    for index, entry in enumerate(startup):
        shell_strings[f"SHELL_AUTOSTART_NAME_{index}"] = entry["name"]
    for label, value in shell_strings.items():
        encoded = ",".join(str(byte) for byte in value.encode("ascii"))
        lines.extend([f"_{label}:", f"        .byte   {encoded},0"])
    lines.append("")
    return "\n".join(lines)


def render_shell(entries: list[dict], manifest: Path) -> str:
    images = [entry for entry in entries if entry["image_manifest"] is not None]
    image_bytes = sum(entry["image_words"] * 3 for entry in images)
    df_text = f"catalog entries={len(entries)} images={len(images)} bytes={image_bytes}"
    lines = [
        "/* Generated by scripts/generate-catalog.py; do not edit. */",
        f"/* Source: {manifest.relative_to(ROOT)} */",
        "",
        "%DEFINE LIBRARY;",
        "",
        f"DCL SHELL_DF_TEXT({len(df_text) + 1}) CHAR INIT('{df_text}');",
    ]
    for index, entry in enumerate(images):
        text = f"{entry['name']} {entry['image_words'] * 3} bytes"
        lines.append(f"DCL SHELL_DU_TEXT_{index}({len(text) + 1}) CHAR INIT('{text}');")
    lines.extend(["", "SHELL_GENERATED_DF: PROC;", "    CALL UART_PUTS(ADDR(SHELL_DF_TEXT));", "    CALL UART_PUTCHAR(10);", "END;", "", "SHELL_GENERATED_DU: PROC;"])
    for index in range(len(images)):
        lines.extend(
            [
                f"    CALL UART_PUTS(ADDR(SHELL_DU_TEXT_{index}));",
                "    CALL UART_PUTCHAR(10);",
            ]
        )
    lines.extend(["END;", ""])

    # Programs the shell starts for itself once a frontend appears. A service
    # is excluded: the shell is flagged autostart because the boot code
    # launches it, and it must not launch itself.
    startup = [
        entry for entry in entries
        if entry["kind"] == "IMAGE_PROGRAM" and "autostart" in entry["flags"]
    ]
    for index, entry in enumerate(startup):
        name = entry["name"]
        lines.append(
            f"DCL SHELL_AUTOSTART_NAME_{index}({len(name) + 1}) CHAR INIT('{name}');"
        )
    lines.extend(["", "SHELL_GENERATED_AUTOSTART: PROC;"])
    if not startup:
        lines.append("    CALL SHELL_STARTUP_NOTHING;")
    for index in range(len(startup)):
        lines.append(
            f"    CALL SHELL_START_ONCE(ADDR(SHELL_AUTOSTART_NAME_{index}));"
        )
    lines.extend(["END;", ""])
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--scheduled-output", type=Path, default=DEFAULT_SCHEDULED_OUTPUT)
    parser.add_argument("--shell-output", type=Path, default=DEFAULT_SHELL_OUTPUT)
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
        shell_rendered = render_shell(entries, args.manifest)
    except (OSError, tomllib.TOMLDecodeError, ValueError) as error:
        print(f"catalog generation failed: {error}", file=sys.stderr)
        return 1

    if args.check:
        try:
            current = args.output.read_text()
            scheduled_current = args.scheduled_output.read_text()
            shell_current = args.shell_output.read_text()
        except OSError as error:
            print(f"catalog check failed: {error}", file=sys.stderr)
            return 1
        if current != rendered or scheduled_current != scheduled_rendered or shell_current != shell_rendered:
            print("catalog check failed: regenerate catalog outputs", file=sys.stderr)
            return 1
        print(f"PASS: catalog is current ({len(load_entries(args.manifest))} entries)")
        return 0

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(rendered)
    args.scheduled_output.parent.mkdir(parents=True, exist_ok=True)
    args.scheduled_output.write_text(scheduled_rendered)
    args.shell_output.parent.mkdir(parents=True, exist_ok=True)
    args.shell_output.write_text(shell_rendered)
    print(f"Generated {len(entries)} entries -> {args.output}, {args.scheduled_output}, {args.shell_output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
