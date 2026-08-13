#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Keep this list sequential. Storage-provider tests create, corrupt, and
# truncate fixtures below build/catalog-images and must not overlap.
RECIPES=(
    run
    plsw-smoke-run
    plsw-link-smoke
    context-switch-smoke
    heartbeat-smoke
    interrupt-context-capability-smoke
    provider-config-smoke
    proc-desc-abi-smoke
    catalog-smoke
    autostart-smoke
    catalog-run-smoke
    catalog-list-smoke
    catalog-spawn-smoke
    scheduled-shell-smoke
    scheduled-catalog-smoke
    scheduled-reclaim-smoke
    scheduled-multislot-smoke
    cor24-image-smoke
    cor24-loader-smoke
    cor24-storage-smoke
    spi-flash-read-smoke
    scheduled-spi-provider-smoke
    scheduled-composite-spi-smoke
    scheduled-concurrent-spi-smoke
    spi-sdcard-smoke
    scheduled-sd-provider-smoke
    scheduled-composite-sd-smoke
    scheduled-concurrent-sd-smoke
    scheduled-composite-sd-mixed-smoke
    scheduled-composite-sd-mixed-reverse-smoke
    i2c-ds1307-smoke
    clock-smoke
)

if [[ "${1:-}" == "--list" ]]; then
    printf '%s\n' "${RECIPES[@]}"
    exit 0
fi

if [[ $# -ne 0 ]]; then
    echo "Usage: $0 [--list]" >&2
    exit 2
fi

cd "$ROOT_DIR"
index=0
for recipe in "${RECIPES[@]}"; do
    index=$((index + 1))
    printf '\n=== emulator acceptance %d/%d: %s ===\n' \
        "$index" "${#RECIPES[@]}" "$recipe"
    just "$recipe"
done

printf '\nPASS: all %d emulator acceptance recipes completed sequentially\n' \
    "${#RECIPES[@]}"

