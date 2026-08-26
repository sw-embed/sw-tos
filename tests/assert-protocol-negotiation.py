#!/usr/bin/env python3

import pathlib
import sys


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
