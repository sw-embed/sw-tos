#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT_DIR/scripts/cor24-storage.py"
OUT_DIR="$ROOT_DIR/build/catalog-images"
STORAGE="$OUT_DIR/swtos-storage.bin"

"$TOOL" build "$STORAGE"
"$TOOL" build "$STORAGE" --check
"$TOOL" validate "$STORAGE"

if "$TOOL" build "$OUT_DIR/storage-bad-alignment.bin" \
    --image-alignment 7 2>/dev/null; then
    echo "FAIL: builder accepted a non-block image alignment" >&2
    exit 1
fi

cp "$STORAGE" "$OUT_DIR/storage-bad-offset.bin"
printf '\377\377\370' | dd of="$OUT_DIR/storage-bad-offset.bin" bs=1 seek=25 conv=notrunc 2>/dev/null
if "$TOOL" validate "$OUT_DIR/storage-bad-offset.bin" 2>/dev/null; then
    echo "FAIL: validator accepted an out-of-range image offset" >&2
    exit 1
fi

cp "$STORAGE" "$OUT_DIR/storage-bad-payload.bin"
printf 'X' | dd of="$OUT_DIR/storage-bad-payload.bin" bs=1 seek=155 conv=notrunc 2>/dev/null
if "$TOOL" validate "$OUT_DIR/storage-bad-payload.bin" 2>/dev/null; then
    echo "FAIL: validator accepted a corrupt stored image" >&2
    exit 1
fi

echo "PASS: block storage is deterministic and rejects corrupt extents and payloads"
