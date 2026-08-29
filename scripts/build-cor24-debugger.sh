#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/cor24-debugger"
EMU_REV=116e165d8f601e4b1c68aba14406913746b24c39
ISA_REV=f7bfc371fb75e13de50d0b3748b7e63c2dba37e5
EMU_SOURCE=""
ISA_SOURCE=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --emulator-source) EMU_SOURCE="$2"; shift 2 ;;
        --isa-source) ISA_SOURCE="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$EMU_SOURCE" ] || [ -z "$ISA_SOURCE" ]; then
    VENDOR_DIR="$OUT_DIR/source"
    EMU_SOURCE="$VENDOR_DIR/sw-cor24-emulator"
    ISA_SOURCE="$VENDOR_DIR/sw-cor24-isa"
    mkdir -p "$VENDOR_DIR"
    if [ ! -d "$EMU_SOURCE/.git" ]; then
        git clone https://github.com/sw-embed/sw-cor24-emulator.git "$EMU_SOURCE"
    fi
    if [ ! -d "$ISA_SOURCE/.git" ]; then
        git clone https://github.com/sw-embed/sw-cor24-isa.git "$ISA_SOURCE"
    fi
    git -C "$EMU_SOURCE" checkout --detach "$EMU_REV"
    git -C "$ISA_SOURCE" checkout --detach "$ISA_REV"
fi

test "$(git -C "$EMU_SOURCE" rev-parse HEAD)" = "$EMU_REV"
test "$(git -C "$ISA_SOURCE" rev-parse HEAD)" = "$ISA_REV"
test "$(dirname "$EMU_SOURCE")/sw-cor24-isa" -ef "$ISA_SOURCE"

# Install an executable by writing beside the target and renaming over it.
#
# Copying onto an existing binary keeps its inode, and the kernel goes on
# validating cached pages against the signature the old contents had. The
# freshly copied file then fails code-signing at exec and is killed outright:
# "SIGKILL (Code Signature Invalid)", even though codesign reports it valid on
# disk. A rename publishes a new inode, so no stale validation can attach to it.
install_executable() {
    cp "$1" "$2.incoming"
    chmod +x "$2.incoming"
    mv -f "$2.incoming" "$2"
}

cargo build --release --manifest-path "$EMU_SOURCE/Cargo.toml" \
    -p cor24-cli --bin cor24-dbg
mkdir -p "$OUT_DIR"
install_executable "$EMU_SOURCE/target/release/cor24-dbg" "$OUT_DIR/cor24-dbg"
"$OUT_DIR/cor24-dbg" --version

ADAPTER_SOURCE="$ROOT_DIR/tools/cor24-debug-adapter"
ADAPTER_BUILD="$OUT_DIR/adapter-source"
mkdir -p "$ADAPTER_BUILD/src"
cp "$ADAPTER_SOURCE/src/main.rs" "$ADAPTER_BUILD/src/main.rs"
sed "s#../../../sw-cor24-emulator#$EMU_SOURCE#" \
    "$ADAPTER_SOURCE/Cargo.toml" > "$ADAPTER_BUILD/Cargo.toml"
cargo build --release --manifest-path "$ADAPTER_BUILD/Cargo.toml"
install_executable "$ADAPTER_BUILD/target/release/swtos-cor24-debug-adapter" \
    "$OUT_DIR/swtos-cor24-debug-adapter"
