#!/bin/bash
#
# List the root directory of an SD card, and say so when there is not one.
#
# The card is a FAT32 image built here rather than committed, so the test
# builds the same volume on any host. That the image is real FAT32 and not a
# private format is the point: the same file mounts on macOS and Linux, so
# what SWTOS lists is what a person sees when they put the card in a laptop.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EMU="$ROOT_DIR/scripts/swtos-emu"
OUT_DIR="$ROOT_DIR/build/sd"
IMAGE="$ROOT_DIR/build/scheduled-shell/program.bin"
CARD="$OUT_DIR/swtos-card.img"
SEED="$OUT_DIR/seed.lgo"

mkdir -p "$OUT_DIR"
"$ROOT_DIR/scripts/mkfat32.py" "$CARD" \
    --file 'HELLO.TXT=Hello from the SD card' \
    --file 'README.TXT=SWTOS test volume' \
    --dir APPS --dir DOCS >/dev/null
# Selects the emulator's peripheral-attaching launch path.
"$ROOT_DIR/tools/bin/cor24-asm" "$ROOT_DIR/tests/spi-launch-seed.s" -o "$SEED" >/dev/null

fail() { echo "FAIL: $1" >&2; echo "$2" >&2; exit 1; }

# With a card: every root entry, directories marked and files sized.
listed=$($EMU --lgo "$SEED" --load-binary "$IMAGE@0" --entry 0 \
    --spi-device "sdcard@cs=2?file=$CARD" \
    -u 'sdls\n' --speed 0 -n 60000000 --quiet 2>/dev/null \
    | sed '/^Entry point:/d')

for expected in 'APPS <dir>' 'DOCS <dir>' 'HELLO.TXT 22' 'README.TXT 17'; do
    grep -q "$expected" <<<"$listed" || fail "no '$expected' in the listing" "$listed"
done

# The volume label is a directory entry too, and it is not a file. Nor are the
# extra entries a long filename is stored across.
grep -q '^SWTOS ' <<<"$listed" && fail "the volume label was listed as a file" "$listed"

# Without a card: a diagnosis, not a blank listing or a hang. This is the case
# on real hardware with an empty slot, and it has to be distinguishable from a
# card that is present and empty.
absent=$($EMU --load-binary "$IMAGE@0" --entry 0 \
    -u 'sdls\n' --speed 0 -n 40000000 --quiet 2>/dev/null \
    | sed '/^Entry point:/d')
grep -q 'no valid SD card detected' <<<"$absent" ||
    fail "a missing card was not reported" "$absent"

# And the shell survives it: a failed read must not take the prompt with it.
after=$($EMU --load-binary "$IMAGE@0" --entry 0 \
    -u 'sdls\nmem\n' --speed 0 -n 40000000 --quiet 2>/dev/null)
grep -q 'total=' <<<"$after" || fail "the shell did not come back from sdls" "$after"

echo "PASS: sdls lists a FAT32 card and reports a missing one"
