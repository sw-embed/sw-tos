#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPORT="$ROOT_DIR/build/emulator-acceptance/report.json"

# Keep this list sequential. Storage-provider tests create, corrupt, and
# truncate fixtures below build/catalog-images and must not overlap.
RECIPES=(
    run
    plsw-smoke-run
    plsw-link-smoke
    complete-lgo-smoke
    context-switch-smoke
    heartbeat-smoke
    interrupt-context-capability-smoke
    preemption-runway-smoke
    preemption-acceptance
    fill-demo-acceptance
    tui-soak
    debugger-kill-acceptance
    shell-command-parsing
    plsw-truncation
    shell-restart
    shell-foreground
    shell-sync-run
    acceptance-report-smoke
    provider-config-smoke
    proc-desc-abi-smoke
    catalog-smoke
    autostart-smoke
    catalog-run-smoke
    catalog-list-smoke
    catalog-spawn-smoke
    scheduled-shell-smoke
    scheduled-stats-smoke
    scheduled-tty-smoke
    protocol-smoke
    protocol-target-smoke
    scheduled-protocol-smoke
    windows-smoke
    debug-info-smoke
    generated-banner-smoke
    emulator-debugger-smoke
    scheduled-catalog-smoke
    scheduled-memory-smoke
    scheduled-reclaim-smoke
    scheduled-multislot-smoke
    scheduled-sixteen-smoke
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

if [[ "${1:-}" == "--report" && $# -eq 2 ]]; then
    REPORT="$2"
    shift 2
fi
if [[ $# -ne 0 ]]; then
    echo "Usage: $0 [--list | --report PATH]" >&2
    exit 2
fi

cd "$ROOT_DIR"
mkdir -p "$ROOT_DIR/build/emulator-acceptance"
RESULTS=$(mktemp "$ROOT_DIR/build/emulator-acceptance/results.XXXXXX")
trap 'rm -f "$RESULTS"' EXIT
STARTED_NS=$(python3 -c 'import time; print(time.time_ns())')
index=0
for recipe in "${RECIPES[@]}"; do
    index=$((index + 1))
    printf '\n=== emulator acceptance %d/%d: %s ===\n' \
        "$index" "${#RECIPES[@]}" "$recipe"
    RECIPE_STARTED_NS=$(python3 -c 'import time; print(time.time_ns())')
    if just "$recipe"; then
        RECIPE_STATUS=pass
        RECIPE_EXIT=0
    else
        RECIPE_EXIT=$?
        RECIPE_STATUS=fail
    fi
    RECIPE_ENDED_NS=$(python3 -c 'import time; print(time.time_ns())')
    printf '%s\t%s\t%d\t%d\n' "$recipe" "$RECIPE_STATUS" "$RECIPE_EXIT" \
        "$((RECIPE_ENDED_NS - RECIPE_STARTED_NS))" >> "$RESULTS"
    if [[ "$RECIPE_STATUS" == "fail" ]]; then
        ENDED_NS=$(python3 -c 'import time; print(time.time_ns())')
        ./scripts/write-acceptance-report.py --results "$RESULTS" \
            --output "$REPORT" --started-ns "$STARTED_NS" \
            --ended-ns "$ENDED_NS" --status fail
        exit "$RECIPE_EXIT"
    fi
done

ENDED_NS=$(python3 -c 'import time; print(time.time_ns())')
./scripts/write-acceptance-report.py --results "$RESULTS" --output "$REPORT" \
    --started-ns "$STARTED_NS" --ended-ns "$ENDED_NS" --status pass
printf '\nPASS: all %d emulator acceptance recipes completed sequentially\n' \
    "${#RECIPES[@]}"
