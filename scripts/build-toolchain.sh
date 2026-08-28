#!/bin/bash
# build-toolchain.sh -- Clone the COR24 toolchain dependencies as peer
# checkouts and build the host binaries this repository expects in
# tools/bin/.
#
# Peer layout (required: the dependency crates use relative path deps):
#
#   <ORGROOT>/sw-cor24-isa            cor24-isa crate (shared ISA tables)
#   <ORGROOT>/sw-cor24-emulator       cor24-emu, cor24-dbg
#   <ORGROOT>/sw-cor24-x-assembler    cor24-asm
#   <ORGROOT>/sw-cor24-plsw           link24, meta-gen (components/linker)
#   <ORGROOT>/sw-cor24-x-tinyc        tc24r (only needed to rebuild plsw.lgo)
#   <ORGROOT>/sw-tos                  this repository
#
# ORGROOT defaults to the parent directory of this repository.
#
# Usage:
#   ./scripts/build-toolchain.sh            # clone missing peers, build, install
#   ./scripts/build-toolchain.sh --check    # verify installed binaries only
#   ./scripts/build-toolchain.sh --no-clone # build from existing peers only

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ORGROOT="${ORGROOT:-$(dirname "$ROOT_DIR")}"
TOOLS_BIN="$ROOT_DIR/tools/bin"

CLONE=1
CHECK_ONLY=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-clone) CLONE=0; shift ;;
        --check) CHECK_ONLY=1; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

# repo -> whether a missing clone is fatal for the tools/bin build
REQUIRED_REPOS="sw-cor24-isa sw-cor24-emulator sw-cor24-x-assembler sw-cor24-plsw"
OPTIONAL_REPOS="sw-cor24-x-tinyc"

check_installed() {
    local missing=0
    for tool in cor24-asm cor24-emu cor24-dbg link24 meta-gen; do
        if [ -x "$TOOLS_BIN/$tool" ]; then
            echo "ok    $TOOLS_BIN/$tool"
        else
            echo "MISSING $TOOLS_BIN/$tool" >&2
            missing=1
        fi
    done
    if [ ! -f "$ROOT_DIR/tools/plsw.lgo" ]; then
        echo "MISSING $ROOT_DIR/tools/plsw.lgo" >&2
        missing=1
    else
        echo "ok    $ROOT_DIR/tools/plsw.lgo"
    fi
    return $missing
}

if [ "$CHECK_ONLY" -eq 1 ]; then
    check_installed
    exit $?
fi

clone_peer() {
    local name="$1"
    local dest="$ORGROOT/$name"
    if [ -d "$dest/.git" ]; then
        echo "peer present: $dest"
        return 0
    fi
    if [ "$CLONE" -eq 0 ]; then
        echo "peer missing (--no-clone): $dest" >&2
        return 1
    fi
    echo "cloning $name into $dest"
    git clone "https://github.com/sw-embed/$name.git" "$dest"
}

mkdir -p "$ORGROOT"
for repo in $REQUIRED_REPOS; do
    clone_peer "$repo"
done
for repo in $OPTIONAL_REPOS; do
    clone_peer "$repo" || echo "optional peer unavailable: $repo" >&2
done

command -v cargo >/dev/null || { echo "error: cargo not on PATH" >&2; exit 1; }

mkdir -p "$TOOLS_BIN"

echo "=== building cor24-emu, cor24-dbg (sw-cor24-emulator) ==="
cargo build --release --manifest-path "$ORGROOT/sw-cor24-emulator/Cargo.toml" -p cor24-cli
install -m 0755 "$ORGROOT/sw-cor24-emulator/target/release/cor24-emu" "$TOOLS_BIN/cor24-emu"
install -m 0755 "$ORGROOT/sw-cor24-emulator/target/release/cor24-dbg" "$TOOLS_BIN/cor24-dbg"

echo "=== building cor24-asm (sw-cor24-x-assembler) ==="
cargo build --release --manifest-path "$ORGROOT/sw-cor24-x-assembler/Cargo.toml" -p cor24-asm-cli
install -m 0755 "$ORGROOT/sw-cor24-x-assembler/target/release/cor24-asm" "$TOOLS_BIN/cor24-asm"

echo "=== building link24, meta-gen (sw-cor24-plsw) ==="
cargo build --release --manifest-path "$ORGROOT/sw-cor24-plsw/components/linker/Cargo.toml"
install -m 0755 "$ORGROOT/sw-cor24-plsw/components/linker/target/release/link24" "$TOOLS_BIN/link24"
install -m 0755 "$ORGROOT/sw-cor24-plsw/components/linker/target/release/meta-gen" "$TOOLS_BIN/meta-gen"

echo "=== installed ==="
check_installed
"$TOOLS_BIN/cor24-emu" --version
"$TOOLS_BIN/cor24-asm" --version
