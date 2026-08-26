#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cargo build --manifest-path "$ROOT_DIR/tools/te-rs/Cargo.toml"
python3 "$ROOT_DIR/tests/test-windows-pty.py"
