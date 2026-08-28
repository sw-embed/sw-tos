#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/i2c-ds1307"

"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/i2c-ds1307.plsw" i2c-ds1307
"$ROOT_DIR/tools/bin/cor24-asm" "$ROOT_DIR/tests/spi-launch-seed.s" \
    -o "$OUT_DIR/seed.lgo"

output=$("$ROOT_DIR/scripts/swtos-emu" \
    --lgo "$OUT_DIR/seed.lgo" \
    --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
    --i2c-device 'ds1307@0x68?hour=12&minute=34&second=56' \
    --i2c-device 'ssd1306@0x3C?width=128&height=64' \
    --speed 0 -n 1000000 --quiet --dump-i2c 2>&1)

if ! echo "$output" | grep -q 'OLED 12:34:56'; then
    echo "FAIL: PL/SW DS1307 client did not print the configured time" >&2
    echo "$output" >&2
    exit 1
fi
if ! echo "$output" | grep -q 'I2C:'; then
    echo "FAIL: emulator recorded no I2C transaction" >&2
    echo "$output" >&2
    exit 1
fi
for event in 'ADDR 0x68 WR ACK' 'WR   0x68 0x00 ACK' \
    'ADDR 0x68 RD ACK' 'RD   0x68 0x56' 'RD   0x68 0x34' \
    'RD   0x68 0x12' 'STOP'; do
    if ! echo "$output" | grep -q "$event"; then
        echo "FAIL: DS1307 transaction log missing '$event'" >&2
        echo "$output" >&2
        exit 1
    fi
done
oled_writes=$(echo "$output" | grep -c 'WR   0x3C')
if [ "$oled_writes" -ne 56 ]; then
    echo "FAIL: SSD1306 expected 56 command/data writes, saw $oled_writes" >&2
    echo "$output" >&2
    exit 1
fi
for event in 'ADDR 0x3C WR ACK' 'WR   0x3C 0xAE ACK' \
    'WR   0x3C 0xAF ACK' 'WR   0x3C 0x40 ACK' \
    'WR   0x3C 0x42 ACK' 'WR   0x3C 0x61 ACK' \
    'WR   0x3C 0x36 ACK'; do
    if ! echo "$output" | grep -q "$event"; then
        echo "FAIL: SSD1306 transaction log missing '$event'" >&2
        echo "$output" >&2
        exit 1
    fi
done

missing_output=$("$ROOT_DIR/scripts/swtos-emu" \
    --lgo "$OUT_DIR/seed.lgo" \
    --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
    --i2c-device 'ssd1306@0x3C?width=128&height=64' \
    --speed 0 -n 1000000 --quiet --dump-i2c 2>&1)
if ! echo "$missing_output" | grep -q 'I2C ERROR'; then
    echo "FAIL: PL/SW DS1307 client did not report a missing device" >&2
    echo "$missing_output" >&2
    exit 1
fi
if ! echo "$missing_output" | grep -q 'ADDR 0x68 WR NAK'; then
    echo "FAIL: missing DS1307 did not exercise the HAL NAK path" >&2
    echo "$missing_output" >&2
    exit 1
fi

missing_oled_output=$("$ROOT_DIR/scripts/swtos-emu" \
    --lgo "$OUT_DIR/seed.lgo" \
    --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
    --i2c-device 'ds1307@0x68?hour=12&minute=34&second=56' \
    --speed 0 -n 1000000 --quiet --dump-i2c 2>&1)
if ! echo "$missing_oled_output" | grep -q 'OLED ERROR'; then
    echo "FAIL: PL/SW display client did not report a missing SSD1306" >&2
    echo "$missing_oled_output" >&2
    exit 1
fi
if ! echo "$missing_oled_output" | grep -q 'ADDR 0x3C WR NAK'; then
    echo "FAIL: missing SSD1306 did not exercise the HAL NAK path" >&2
    echo "$missing_oled_output" >&2
    exit 1
fi

echo "PASS: PL/SW rendered DS1307 time 12:34:56 on the emulated SSD1306"
