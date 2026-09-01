#!/bin/bash
# Remove reproducible build outputs while preserving captured hardware evidence.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"

if [ ! -d "$BUILD_DIR" ]; then
    exit 0
fi

find "$BUILD_DIR" -mindepth 1 -maxdepth 1 ! -name captures -exec rm -rf -- {} +
