#!/usr/bin/env python3
"""Check a storage layout against the contract, not against its numbers.

The layout is a data contract with another repo: sw-mlpl parses it and
native3d draws it. What must hold is that columns stay index-aligned, regions
tile the whole capacity with no gap or overlap, ids are usable for picking,
and edges point at regions that exist. The numbers change every time a program
is added; none of that may.

    validate-storage-layout.py LAYOUT [STORAGE-IMAGE]

The image is optional and is given only when the layout should describe that
exact build. A published sample describes whichever build produced it, so it
is held to the contract but not to today's figures.
"""

import json
import sys
from pathlib import Path

SCHEMA = "sw-ml-study.system-layout"
#: Every kind a consumer must have a colour for. An unfamiliar kind is not
#: wrong -- it is a new thing to draw -- but it should be a deliberate
#: addition on both sides rather than a surprise in someone's renderer.
KNOWN_KINDS = {"header", "catalog", "image", "padding", "free"}


def validate(doc: dict, image: bytes | None) -> list[str]:
    failures: list[str] = []

    def check(condition, message):
        if not condition:
            failures.append(message)

    # Every column a consumer reads must be present. A missing column reads as
    # an empty array downstream, which is a silently wrong picture rather than
    # an error.
    required = [
        "spaces", "space_name", "space_block", "space_capacity",
        "region_id", "region_space", "region_kind", "region_name",
        "region_owner", "region_start", "region_length",
        "region_text_words", "region_data_words", "region_bss_words",
        "rel_kind", "rel_from", "rel_to",
    ]
    missing = [name for name in required if name not in doc]
    check(not missing, f"missing columns: {missing}")
    if missing:
        return failures

    # The identifying header. `schema` is how a consumer tells this document
    # from any other columnar file; `provenance` is how a rendered picture is
    # traced back to the tree that drew it.
    check(doc.get("schema") == SCHEMA, f"schema is {doc.get('schema')!r}")
    check(doc.get("version") == 1, f"version is {doc.get('version')}, expected 1")
    provenance = doc.get("provenance")
    check(isinstance(provenance, dict),
          f"provenance is {type(provenance).__name__}, expected an object")
    if isinstance(provenance, dict):
        check(provenance.get("producer") == "sw-tos",
              f"producer is {provenance.get('producer')!r}")
        check(bool(provenance.get("revision")), "provenance carries no revision")

    spaces = doc["spaces"]
    regions = len(doc["region_kind"])
    programs = len(doc.get("program_name", []))

    for name, column in doc.items():
        if name.startswith("space_"):
            check(len(column) == len(spaces),
                  f"{name} has {len(column)} entries, {len(spaces)} spaces")
        elif name.startswith("region_"):
            check(len(column) == regions,
                  f"{name} has {len(column)} entries, {regions} regions")
        elif name.startswith("program_"):
            check(len(column) == programs,
                  f"{name} has {len(column)} entries, {programs} programs")

    check(all(space in spaces for space in doc["region_space"]),
          "a region names a space that is not declared")

    # native3d picks and cross-highlights by region id, so a duplicate would
    # select two regions at once and a zero would collide with "no region".
    ids = doc["region_id"]
    check(len(set(ids)) == len(ids), "region ids are not unique")
    check(all(isinstance(value, int) and value > 0 for value in ids),
          "a region id is not a positive integer")

    # The edge table is length E, independent of N, and every endpoint must
    # name a region that exists: an edge to nothing draws a line into space.
    edges = len(doc["rel_kind"])
    for name in ("rel_from", "rel_to"):
        check(len(doc[name]) == edges,
              f"{name} has {len(doc[name])} entries, {edges} relationships")
        check(all(endpoint in ids for endpoint in doc[name]),
              f"{name} names a region id that does not exist")
    check(all(isinstance(kind, str) and kind for kind in doc["rel_kind"]),
          "a relationship has no kind")

    # The regions must tile the space: address order, no gap, no overlap,
    # ending exactly at capacity. A viewer draws what it is given, so a hole
    # here becomes a hole on screen that nothing in the system actually has.
    cursor = 0
    for index in range(regions):
        start, length = doc["region_start"][index], doc["region_length"][index]
        check(start == cursor,
              f"region {index} ({doc['region_name'][index]}) starts at {start}, "
              f"expected {cursor}")
        check(length > 0, f"region {index} has length {length}")
        cursor = start + length
    check(cursor == doc["space_capacity"][0],
          f"regions cover {cursor} bytes, capacity is {doc['space_capacity'][0]}")

    unknown = set(doc["region_kind"]) - KNOWN_KINDS
    check(not unknown, f"undeclared region kinds: {sorted(unknown)}")

    check(doc["region_length"][0] == 8, "header region is not the 8-byte header")
    stored = sorted(doc["region_name"][i] for i in range(regions)
                    if doc["region_kind"][i] == "image")
    catalogued = sorted(doc["program_name"][i] for i in range(programs)
                        if doc["program_has_image"][i])
    check(stored == catalogued,
          f"image regions {stored} do not match catalogued images {catalogued}")

    # A catalogued program points at its region, so "explain this program" can
    # start from the catalog. A program with no stored image points at nothing.
    for index in range(programs):
        region = doc["program_region"][index]
        if doc["program_has_image"][index]:
            check(region in ids,
                  f"program {doc['program_name'][index]} names region {region}, "
                  f"which does not exist")
        else:
            check(region == 0,
                  f"program {doc['program_name'][index]} has no image but "
                  f"names region {region}")

    # Word counts belong to images and are zero everywhere else, so a consumer
    # can sum a column without filtering it first.
    for index in range(regions):
        if doc["region_kind"][index] != "image":
            check(doc["region_text_words"][index] == 0,
                  f"region {index} is not an image but has text words")

    # The layout must describe the image it was given, not a stale one.
    if image is not None:
        check(programs == image[0],
              f"{programs} programs listed, image header says {image[0]}")

    return failures


def main() -> int:
    if not 2 <= len(sys.argv) <= 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    path = Path(sys.argv[1])
    image = Path(sys.argv[2]).read_bytes() if len(sys.argv) > 2 else None
    doc = json.loads(path.read_text())
    failures = validate(doc, image)
    if failures:
        print(f"FAIL: {path} does not meet the storage layout contract",
              file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        return 1
    print(f"{path.name}: {len(doc['region_kind'])} regions, "
          f"{len(doc['rel_kind'])} relationships over "
          f"{doc['space_capacity'][0]} bytes in {doc['spaces'][0]}, "
          f"{len(doc['program_name'])} programs, {doc['schema']} at "
          f"{doc['provenance']['revision']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
