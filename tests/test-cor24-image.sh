#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT_DIR/scripts/cor24-image.py"
MANIFEST="$ROOT_DIR/catalog/images/loader-smoke.toml"
OUT_DIR="$ROOT_DIR/build/catalog-images"
IMAGE="$OUT_DIR/loader-smoke.c24"

"$TOOL" build "$MANIFEST" "$IMAGE"
"$TOOL" build "$MANIFEST" "$IMAGE" --check
"$TOOL" validate "$IMAGE"

cp "$IMAGE" "$OUT_DIR/bad-magic.c24"
printf 'X' | dd of="$OUT_DIR/bad-magic.c24" bs=1 seek=0 conv=notrunc 2>/dev/null
if "$TOOL" validate "$OUT_DIR/bad-magic.c24" 2>/dev/null; then
    echo "FAIL: validator accepted corrupt magic" >&2
    exit 1
fi

cp "$IMAGE" "$OUT_DIR/bad-payload.c24"
printf 'X' | dd of="$OUT_DIR/bad-payload.c24" bs=1 seek=27 conv=notrunc 2>/dev/null
if "$TOOL" validate "$OUT_DIR/bad-payload.c24" 2>/dev/null; then
    echo "FAIL: validator accepted corrupt payload" >&2
    exit 1
fi

cp "$IMAGE" "$OUT_DIR/truncated.c24"
truncate -s 29 "$OUT_DIR/truncated.c24"
if "$TOOL" validate "$OUT_DIR/truncated.c24" 2>/dev/null; then
    echo "FAIL: validator accepted truncated payload" >&2
    exit 1
fi

echo "PASS: COR24 image builder rejected magic, checksum, and length corruption"
