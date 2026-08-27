#!/usr/bin/env python3

import pathlib
import sys


def main() -> int:
    output = pathlib.Path(sys.argv[1]).read_bytes()
    ack = bytes.fromhex("c2 a5 5a 01 0d 04 53 57 54 31 41")
    framed_time = b"".join(
        bytes.fromhex(frame)
        for frame in (
            "c2 a5 5a 01 02 01 01 54 59",
            "c2 a5 5a 01 02 01 01 49 4e",
            "c2 a5 5a 01 02 01 01 4d 52",
            "c2 a5 5a 01 02 01 01 45 4a",
        )
    )
    if b"R\n" not in output or output.count(ack) != 1 or framed_time not in output:
        print("FAIL: typed uptime payload was not isolated and delivered intact", file=sys.stderr)
        print(output.hex(" "), file=sys.stderr)
        return 1
    print("PASS: typed uptime payload remained outside TTY traffic and preserved escapes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
