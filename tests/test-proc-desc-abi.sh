#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT_DIR/scripts/check-proc-desc-abi.py"

if ! grep -q '^        \.zero   39$' "$ROOT_DIR/hal/cor24/catalog-spawn.s"; then
    echo "FAIL: scheduled kernel process slots are not 39-byte records" >&2
    exit 1
fi

echo "PASS: scheduled kernel allocates process slots at the declared ABI size"
