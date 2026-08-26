#!/usr/bin/env python3

import json
import pathlib
import sys


def render_uart(data: bytes) -> bytes:
    return b"".join(chr(byte).encode() for byte in data if byte != 0)


def main() -> int:
    output = pathlib.Path(sys.argv[1]).read_bytes()
    if b"SPAWN\n" not in output:
        print("FAIL: scheduled image did not reach its blocked TTY readers", file=sys.stderr)
        return 1
    # Quiet-mode rendering omits NUL and UTF-8-encodes bytes above ASCII, so
    # verify both the emitted visible sequence and the exact assembled record.
    rendered_ack = bytes.fromhex("c2 a5 5a 01 0d 04 53 57 54 31 41")
    listing = pathlib.Path(sys.argv[2]).read_text()
    encoded_ack = "A5 5A 01 0D 00 04 00 53 57 54 31 41"
    if output.count(rendered_ack) != 2 or encoded_ack not in listing:
        print("FAIL: scheduled kernel did not ACK initial and reconnect HELLO", file=sys.stderr)
        print(output.hex(" "), file=sys.stderr)
        return 1
    resource_prefix = bytes.fromhex("c2 a5 5a 01 08")
    if output.count(resource_prefix) < 10:
        print("FAIL: scheduled kernel did not emit fresh resource snapshots after reconnect", file=sys.stderr)
        print(output.hex(" "), file=sys.stderr)
        return 1
    debug = json.loads(pathlib.Path(sys.argv[3]).read_text())
    build_id = int(debug["build_id"].split(":", 1)[1], 16)
    payload = bytes((1, build_id & 0xFF, (build_id >> 8) & 0xFF, build_id >> 16))
    raw_response = bytes((0xA5, 0x5A, 1, 10, 0, 4, 0)) + payload
    raw_response += bytes((sum(raw_response[2:]) & 0xFF,))
    rendered_response = render_uart(raw_response)
    if rendered_response not in output:
        print("FAIL: target build identity does not match program.debug.json", file=sys.stderr)
        print(output.hex(" "), file=sys.stderr)
        return 1
    debug_prefix = bytes.fromhex("c2 a5 5a 01 0a")
    if output.count(debug_prefix) < 4:
        print("FAIL: target did not return identity, register, and memory records", file=sys.stderr)
        return 1
    memory_payload = bytes((3, 0, 0, 0)) + pathlib.Path(sys.argv[4]).read_bytes()[:4]
    memory_response = bytes((0xA5, 0x5A, 1, 10, 0, len(memory_payload), 0)) + memory_payload
    memory_response += bytes((sum(memory_response[2:]) & 0xFF,))
    if render_uart(memory_response) not in output:
        print("FAIL: read-only debug memory response did not match linked image", file=sys.stderr)
        return 1
    tty_x = bytes.fromhex("c2 a5 5a 01 02 01 01 58 5d")
    tty_y = bytes.fromhex("c2 a5 5a 01 02 02 01 59 5f")
    if output.count(tty_x) != 1 or output.count(tty_y) != 1:
        print("FAIL: framed TTY input did not wake and route to channels one and two", file=sys.stderr)
        print(output.hex(" "), file=sys.stderr)
        return 1
    print("PASS: scheduled kernel negotiated framing and routed isolated TTY input")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
