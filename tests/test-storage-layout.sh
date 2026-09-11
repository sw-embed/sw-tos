#!/bin/bash
#
# Emit the storage layout and hold it to the contract. The checking lives in
# tests/validate-storage-layout.py, because two things are checked with it:
# what this build produces now, and the sample published for another repo to
# develop against before it can run this build.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="$ROOT_DIR/build/catalog-images/swtos-storage.bin"
LAYOUT="$ROOT_DIR/build/storage-layout.json"
SAMPLE="$ROOT_DIR/examples/viz/storage-layout.json"

if [ ! -f "$IMAGE" ]; then
    echo "SKIP: no storage image at $IMAGE (run just cor24-storage-smoke)" >&2
    exit 0
fi

"$ROOT_DIR/scripts/storage-layout.py" "$IMAGE" -o "$LAYOUT" >/dev/null
"$ROOT_DIR/tests/validate-storage-layout.py" "$LAYOUT" "$IMAGE"

# The published sample is a snapshot, not a golden file: its figures are
# whatever build produced it, and `just storage-layout-publish` refreshes it.
# Holding it to the contract is what stops it going structurally stale, which
# is the kind of staleness that breaks a consumer.
if [ -f "$SAMPLE" ]; then
    "$ROOT_DIR/tests/validate-storage-layout.py" "$SAMPLE"
fi
