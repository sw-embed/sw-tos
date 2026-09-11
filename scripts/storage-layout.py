#!/usr/bin/env python3
"""Emit the semantic layout of a SWTOS storage image as JSON.

This is the boundary described in sw-ml-study/demo-extensions/docs/research.txt:

    sw-tos  ->  storage-layout.json  ->  MLPL script  ->  native3d  ->  viewer

SWTOS knows storage semantics. MLPL knows visualization semantics. native3d
knows graphics. Nothing downstream has to learn the catalog format, and this
script draws nothing.

Every figure comes from cor24-storage.py and cor24-image.py -- the same modules
the build and the validator use -- rather than being recomputed here, so the
picture cannot drift from the image it claims to describe.

The shape is COLUMNAR (struct-of-arrays), pinned by sw-mlpl in
sw-ml-study/sw-mlpl/docs/storage-layout-viz.md: every `region_*` array has the
same length N and is index-aligned, every `space_*` array has length S, and
`spaces[i]` is the key `region_space` joins on. That shape is not a style
preference -- MLPL's parse_json ingests homogeneous arrays and string lists
today, while an array-of-objects would need a language feature that does not
exist. Writing rows here would push the cost onto the consumer.

A region's `kind` is what it is, not how to draw it: choosing colour, scale and
arrangement is the consumer's job. The kinds emitted are

    header    the eight-byte catalog header
    catalog   the fixed 24-byte records, one per program
    image     a stored C24IMG extent, block-aligned
    padding   alignment between an image and the next block boundary
    free      space past the last extent

so that "free" and "padding" stay distinguishable: one is unused capacity, the
other is the cost of block alignment, and a visualizer that shows them the same
way hides what the alignment costs.

`region_id` is what the viewer picks and cross-highlights by, so it comes from
the catalog ordinal -- what the system itself uses to identify a program --
rather than from a position in this document, which moves whenever a program is
added. `rel_*` is an edge table saying what explains what, and `provenance`
names the tree that produced the picture, dirty trees included.
"""

import argparse
import importlib.util
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


storage_tool = load_module("swtos_storage", ROOT / "scripts" / "cor24-storage.py")
image_tool = load_module("swtos_image", ROOT / "scripts" / "cor24-image.py")

BLOCK = storage_tool.BLOCK_BYTES
HEADER = storage_tool.HEADER_BYTES
RECORD = storage_tool.RECORD_BYTES
NAME = storage_tool.NAME_BYTES
HAS_IMAGE = storage_tool.FLAG_HAS_IMAGE


def catalog_records(data: bytes) -> list[dict]:
    """Every catalog record, decoded. Order is ordinal order, which is also
    the order the records sit in the image."""
    count = data[0]
    records = []
    for ordinal in range(count):
        start = HEADER + ordinal * RECORD
        record = data[start : start + RECORD]
        records.append({
            "ordinal": ordinal,
            "name": record[:NAME].split(b"\0", 1)[0].decode("ascii"),
            "record_start": start,
            "record_length": RECORD,
            "offset": int.from_bytes(record[17:20], "big"),
            "length": int.from_bytes(record[20:23], "big"),
            "has_image": bool(record[23] & HAS_IMAGE),
        })
    return records


def image_fields(extent: bytes) -> dict:
    """The C24IMG header of a stored image, so a consumer can show what the
    extent is made of without parsing the format itself."""
    header = image_tool.parse_header(extent) if hasattr(image_tool, "parse_header") else None
    if header is not None:
        return header
    # The tool validates rather than exposing a parser; read the documented
    # header directly. Nine 24-bit words, big endian, after the magic.
    words = [int.from_bytes(extent[i : i + 3], "big") for i in range(6, 6 + 8 * 3, 3)]
    return {
        "version": words[0],
        "text_words": words[1],
        "data_words": words[2],
        "bss_words": words[3],
        "entry_offset": words[4],
        "relocation_count": words[5],
    }


#: What a stored image is read through. The bytes are identical either way --
#: the same image is flashed to NOR or written to a card -- but the device
#: decides the space a visualizer draws the free capacity against.
PROVIDERS = {
    "w25q32": {"space": "flash", "name": "W25Q32 storage", "capacity": 4 * 1024 * 1024},
    "sdcard": {"space": "sd", "name": "SD card", "capacity": None},
    "resident": {"space": "image", "name": "linked image", "capacity": None},
}

#: The contract's constant name, so a consumer can tell this document from
#: another columnar file without guessing from its fields. MLOS emits the same
#: schema, which is the point of naming it rather than the producer.
SCHEMA = "sw-ml-study.system-layout"
PRODUCER = "sw-tos"

#: Region ids must be stable across snapshots -- native3d picks and
#: cross-highlights by id, so an id that shifts when a program is added would
#: move the selection to a different region. A positional index does exactly
#: that, so ids come from what the system itself uses to identify a thing: the
#: catalog ordinal. The fixed regions take low ids of their own, and a
#: padding region borrows the ordinal of the image that imposed it.
ID_HEADER, ID_CATALOG, ID_FREE = 1, 2, 3
ID_IMAGE_BASE, ID_PADDING_BASE = 100, 200

#: Regions that belong to no program. The catalog and its header are the
#: kernel's bookkeeping; free space is owned by nobody, and saying so is not
#: the same as calling it the kernel's.
KERNEL, NOBODY = "kernel", ""


def walk(data: bytes, records: list[dict], total: int) -> list[dict]:
    """Every region in address order with no gaps, as rows. They are turned
    into columns immediately afterwards; rows are only the natural way to
    walk an image once."""
    index_end = HEADER + len(records) * RECORD
    rows = [
        {"id": ID_HEADER, "kind": "header", "name": "storage header",
         "owner": KERNEL, "start": 0, "length": HEADER},
        {"id": ID_CATALOG, "kind": "catalog", "name": "catalog records",
         "owner": KERNEL, "start": HEADER, "length": index_end - HEADER},
    ]

    # Images in address order, which ordinal order need not be.
    stored = sorted((r for r in records if r["has_image"]), key=lambda r: r["offset"])
    cursor = index_end
    for record in stored:
        if record["offset"] > cursor:
            # Alignment is a cost the following image imposes, so name it as
            # that image's, not as anonymous slack.
            rows.append({"id": ID_PADDING_BASE + record["ordinal"],
                         "kind": "padding", "name": "block alignment",
                         "owner": record["name"], "start": cursor,
                         "length": record["offset"] - cursor})
        extent = data[record["offset"] : record["offset"] + record["length"]]
        rows.append({
            "id": ID_IMAGE_BASE + record["ordinal"],
            "kind": "image",
            "name": record["name"],
            "owner": record["name"],
            "ordinal": record["ordinal"],
            "start": record["offset"],
            "length": record["length"],
            **image_fields(extent),
        })
        cursor = record["offset"] + record["length"]

    if cursor < total:
        rows.append({"id": ID_FREE, "kind": "free", "name": "unused",
                     "owner": NOBODY, "start": cursor,
                     "length": total - cursor})
    return rows


def relationships(rows: list[dict]) -> dict:
    """The edge table: what explains what. Length E, independent of N.

    Only `describes` exists at this phase -- a catalog record describes the
    extent it points at, which is the first link of the "explain selected
    program" chain (catalog -> extent -> C24IMG -> allocation). The rest of
    that chain is `loads-to`, from a stored extent to the RAM it is loaded
    into, and there is no RAM in a static image: it arrives with the runtime
    snapshot rather than being invented here.
    """
    images = [row["id"] for row in rows if row["kind"] == "image"]
    return {
        "rel_kind": ["describes"] * len(images),
        "rel_from": [ID_CATALOG] * len(images),
        "rel_to": images,
    }


def revision() -> str:
    """The producer's source revision, so a rendered snapshot is traceable
    back to the tree that produced it. A dirty tree is marked as such: a bare
    hash would claim a picture came from committed sources when it did not."""
    import subprocess
    try:
        head = subprocess.run(["git", "rev-parse", "--short", "HEAD"],
                              cwd=ROOT, capture_output=True, text=True, check=True)
        dirty = subprocess.run(["git", "status", "--porcelain"],
                               cwd=ROOT, capture_output=True, text=True, check=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        return "unknown"
    return head.stdout.strip() + ("-dirty" if dirty.stdout.strip() else "")


def layout(data: bytes, capacity: int | None, provider: str,
           source: str | None = None) -> dict:
    """The columnar document. `used` is the address the last extent ends at,
    which is what a capacity bar should fill to."""
    storage_tool.validate_storage(data)
    records = catalog_records(data)
    device = PROVIDERS[provider]
    total = capacity or device["capacity"] or len(data)
    rows = walk(data, records, total)
    space = device["space"]

    def column(field, default=0):
        return [row.get(field, default) for row in rows]

    return {
        "schema": SCHEMA,
        "version": 1,
        "provenance": {"producer": PRODUCER,
                       "revision": source or revision()},

        "spaces": [space],
        "space_name": [device["name"]],
        "space_block": [BLOCK],
        "space_capacity": [total],
        "space_used": [max((r["start"] + r["length"]) for r in rows
                           if r["kind"] != "free")],

        "region_id": column("id"),
        "region_space": [space] * len(rows),
        "region_kind": column("kind"),
        "region_name": column("name"),
        "region_owner": column("owner"),
        "region_start": column("start"),
        "region_length": column("length"),

        "region_text_words": column("text_words"),
        "region_data_words": column("data_words"),
        "region_bss_words": column("bss_words"),

        **relationships(rows),

        # The catalog holds a record per program whether or not an image is
        # stored, so a program with no image has no region of its own. These
        # columns keep it visible; they are length P, not length N.
        "program_name": [r["name"] for r in records],
        "program_ordinal": [r["ordinal"] for r in records],
        "program_has_image": [1 if r["has_image"] else 0 for r in records],
        "program_offset": [r["offset"] for r in records],
        "program_length": [r["length"] for r in records],
        "program_region": [ID_IMAGE_BASE + r["ordinal"] if r["has_image"] else 0
                           for r in records],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("image", type=Path, nargs="?",
                        default=ROOT / "build" / "catalog-images" / "swtos-storage.bin",
                        help="a storage image built by cor24-storage.py")
    parser.add_argument("-o", "--output", type=Path,
                        default=ROOT / "build" / "storage-layout.json")
    parser.add_argument("--provider", choices=sorted(PROVIDERS), default="w25q32",
                        help="the device the image is read through; decides the "
                             "capacity and the granule worth outlining")
    parser.add_argument("--revision", default=None,
                        help="record this as the producer revision instead of "
                             "asking git (for a reproducible artifact)")
    parser.add_argument("--capacity", type=int, default=None,
                        help="device capacity in bytes, if larger than the image "
                             "(a 4 MiB W25Q32 holds a much smaller image)")
    args = parser.parse_args()

    if not args.image.exists():
        print(f"storage-layout: no image at {args.image}; "
              f"run `just cor24-storage-smoke` to build one", file=sys.stderr)
        return 1

    try:
        document = layout(args.image.read_bytes(), args.capacity, args.provider,
                          args.revision)
    except ValueError as error:
        print(f"storage-layout: {args.image} is not a valid storage image: {error}",
              file=sys.stderr)
        return 1

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(document, indent=2) + "\n")
    kinds = {}
    for kind in document["region_kind"]:
        kinds[kind] = kinds.get(kind, 0) + 1
    summary = " ".join(f"{name}={count}" for name, count in sorted(kinds.items()))
    print(f"{args.output}: {len(document['region_kind'])} regions ({summary}), "
          f"{len(document['rel_kind'])} relationships, "
          f"{document['space_used'][0]} of {document['space_capacity'][0]} "
          f"bytes used in {document['spaces'][0]} "
          f"at {document['provenance']['revision']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
