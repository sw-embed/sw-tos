#!/bin/bash

set -euo pipefail

# Go and Cargo install user-facing binaries outside the login-shell PATH on
# some build hosts. Construct the same deterministic search path for every
# demo recipe while preserving explicitly configured GOPATH/CARGO_HOME values.
demo_go_root="${GOPATH:-${HOME}/go}"
demo_cargo_root="${CARGO_HOME:-${HOME}/.cargo}"
demo_tool_path="$demo_go_root/bin:$demo_cargo_root/bin:${HOME}/.local/bin:$PATH"

for demo_tool in vhs cargo ffmpeg; do
    if ! PATH="$demo_tool_path" command -v "$demo_tool" >/dev/null; then
        echo "missing demo prerequisite: $demo_tool" >&2
        exit 127
    fi
done

if [ "${1:-}" = "--check" ]; then
    PATH="$demo_tool_path" command -v vhs cargo ffmpeg
    PATH="$demo_tool_path" vhs --version
    PATH="$demo_tool_path" cargo --version
    PATH="$demo_tool_path" ffmpeg -version | sed -n '1p'
    exit 0
fi

exec env PATH="$demo_tool_path" "$@"
