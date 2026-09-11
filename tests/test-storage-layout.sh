#!/bin/bash
#
# The storage layout emitted for the visualization pipeline is a data
# contract with another repo (sw-mlpl parses it, native3d draws it), so what
# is checked here is the contract, not the numbers: columns that stay aligned,
# regions that tile the whole capacity with no gap and no overlap, and totals
# that agree with the image the layout claims to describe.
#
# Numbers change every time a program is added. Alignment and coverage must
# not, and a consumer cannot tell a dropped column from an empty one.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="$ROOT_DIR/build/catalog-images/swtos-storage.bin"
LAYOUT="$ROOT_DIR/build/storage-layout.json"

if [ ! -f "$IMAGE" ]; then
    echo "SKIP: no storage image at $IMAGE (run just cor24-storage-smoke)" >&2
    exit 0
fi

"$ROOT_DIR/scripts/storage-layout.py" "$IMAGE" -o "$LAYOUT" >/dev/null

python3 - "$IMAGE" "$LAYOUT" <<'PY'
import json
import sys

image = open(sys.argv[1], "rb").read()
doc = json.loads(open(sys.argv[2]).read())
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


# Every column a consumer reads must be present. A missing column reads as an
# empty array downstream, which is a silently wrong picture rather than an error.
required = [
    "spaces", "space_name", "space_block", "space_capacity",
    "region_space", "region_kind", "region_name", "region_owner",
    "region_start", "region_length",
    "region_text_words", "region_data_words", "region_bss_words",
]
missing = [name for name in required if name not in doc]
check(not missing, f"missing columns: {missing}")
check(doc.get("version") == 1, f"version is {doc.get('version')}, expected 1")
if missing:
    print("\n".join(failures), file=sys.stderr)
    raise SystemExit(1)

spaces = doc["spaces"]
regions = len(doc["region_kind"])

for name, column in doc.items():
    if name.startswith("space_"):
        check(len(column) == len(spaces),
              f"{name} has {len(column)} entries, {len(spaces)} spaces")
    elif name.startswith("region_"):
        check(len(column) == regions,
              f"{name} has {len(column)} entries, {regions} regions")

check(all(space in spaces for space in doc["region_space"]),
      "a region names a space that is not declared")

# The regions must tile the space: address order, no gap, no overlap, ending
# exactly at capacity. A visualizer draws what it is given, so a hole here
# becomes a hole on screen that nothing in the system actually has.
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

# Every kind a consumer must colour. An unknown kind is not an error here --
# it is a new thing to draw -- but it should be a deliberate addition.
known = {"header", "catalog", "image", "padding", "free"}
unknown = set(doc["region_kind"]) - known
check(not unknown, f"undeclared region kinds: {sorted(unknown)}")

# The layout must describe the image it was given, not a stale one.
check(doc["region_length"][0] == 8, "header region is not the 8-byte header")
stored = [doc["region_name"][i] for i in range(regions)
          if doc["region_kind"][i] == "image"]
catalogued = [doc["program_name"][i] for i in range(len(doc["program_name"]))
              if doc["program_has_image"][i]]
check(sorted(stored) == sorted(catalogued),
      f"image regions {sorted(stored)} do not match catalogued images "
      f"{sorted(catalogued)}")
check(len(doc["program_name"]) == image[0],
      f"{len(doc['program_name'])} programs listed, image header says {image[0]}")

# Word counts belong to images and are zero everywhere else, so a consumer can
# sum a column without filtering it first.
for index in range(regions):
    if doc["region_kind"][index] != "image":
        check(doc["region_text_words"][index] == 0,
              f"region {index} is not an image but has text words")

if failures:
    print("FAIL: storage layout contract", file=sys.stderr)
    print("\n".join(f"  {failure}" for failure in failures), file=sys.stderr)
    raise SystemExit(1)

print(f"storage layout contract: {regions} regions over "
      f"{doc['space_capacity'][0]} bytes in {spaces[0]}, "
      f"{len(doc['program_name'])} programs")
PY
