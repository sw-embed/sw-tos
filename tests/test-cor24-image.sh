#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT_DIR/scripts/cor24-image.py"
ASM="$ROOT_DIR/tools/bin/cor24-asm"
MANIFEST="$ROOT_DIR/catalog/images/loader-smoke.toml"
OUT_DIR="$ROOT_DIR/build/catalog-images"
IMAGE="$OUT_DIR/loader-smoke.c24"

"$TOOL" build "$MANIFEST" "$IMAGE"
"$TOOL" build "$MANIFEST" "$IMAGE" --check
"$TOOL" validate "$IMAGE"

LARGE_IMAGE="$OUT_DIR/embedded-hello-large.c24"
"$TOOL" build "$ROOT_DIR/catalog/images/embedded-hello-large.toml" "$LARGE_IMAGE"
"$TOOL" validate "$LARGE_IMAGE"
if [ "$(wc -c < "$LARGE_IMAGE" | tr -d ' ')" != 546 ]; then
    echo "FAIL: zero-filled cross-sector image is not 546 bytes" >&2
    exit 1
fi

"$ASM" "$ROOT_DIR/catalog/images/embedded-hello.s" \
    --bin "$OUT_DIR/embedded-hello.bin" -o "$OUT_DIR/embedded-hello.lgo"
"$TOOL" build "$ROOT_DIR/catalog/images/embedded-hello.toml" \
    "$OUT_DIR/embedded-hello.c24"
tail -c +28 "$OUT_DIR/embedded-hello.c24" > "$OUT_DIR/embedded-hello-payload.bin"
if ! cmp -s "$OUT_DIR/embedded-hello.bin" "$OUT_DIR/embedded-hello-payload.bin"; then
    echo "FAIL: embedded-hello manifest payload differs from assembled source" >&2
    exit 1
fi

"$ROOT_DIR/scripts/plsw-pipeline.sh" "$ROOT_DIR/catalog/images/embedded-ping.plsw"
"$ASM" "$ROOT_DIR/build/embedded-ping.s" \
    --bin "$OUT_DIR/embedded-ping.bin" -o "$OUT_DIR/embedded-ping.lgo"
"$TOOL" build "$ROOT_DIR/catalog/images/embedded-ping.toml" \
    "$OUT_DIR/embedded-ping.c24"
tail -c +28 "$OUT_DIR/embedded-ping.c24" > "$OUT_DIR/embedded-ping-payload.bin"
cp "$OUT_DIR/embedded-ping.bin" "$OUT_DIR/embedded-ping-padded.bin"
printf '\000' >> "$OUT_DIR/embedded-ping-padded.bin"
if ! cmp -s "$OUT_DIR/embedded-ping-padded.bin" "$OUT_DIR/embedded-ping-payload.bin"; then
    echo "FAIL: embedded-ping manifest payload differs from compiled PL/SW source" >&2
    exit 1
fi

"$ASM" "$ROOT_DIR/catalog/images/cpu-hog.s" \
    --bin "$OUT_DIR/cpu-hog.bin" -o "$OUT_DIR/cpu-hog.lgo"
"$TOOL" build "$ROOT_DIR/catalog/images/cpu-hog.toml" \
    "$OUT_DIR/cpu-hog.c24"
tail -c +28 "$OUT_DIR/cpu-hog.c24" > "$OUT_DIR/cpu-hog-payload.bin"
cp "$OUT_DIR/cpu-hog.bin" "$OUT_DIR/cpu-hog-padded.bin"
printf '\000\000' >> "$OUT_DIR/cpu-hog-padded.bin"
if ! cmp -s "$OUT_DIR/cpu-hog-padded.bin" "$OUT_DIR/cpu-hog-payload.bin"; then
    echo "FAIL: cpu-hog manifest payload differs from assembled source" >&2
    exit 1
fi

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

echo "PASS: COR24 images match source, support zero-filled data, and reject corruption"
