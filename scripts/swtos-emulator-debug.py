#!/usr/bin/env python3
"""Run the SWTOS window frontend against the tracked COR24 emulator adapter."""

import argparse
import os
import pathlib
import pty
import signal
import subprocess
import sys
import tty


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("image", type=pathlib.Path)
    parser.add_argument("debug_map", type=pathlib.Path)
    parser.add_argument("te_args", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parent.parent
    adapter = root / "build/cor24-debugger/swtos-cor24-debug-adapter"
    frontend = root / "tools/te-rs/target/release/te-rs"
    for artifact in (adapter, frontend, args.image, args.debug_map):
        if not artifact.exists():
            parser.error(f"missing {artifact}")

    master, slave = pty.openpty()
    tty.setraw(slave)
    os.set_blocking(master, False)
    slave_name = os.ttyname(slave)
    proc = subprocess.Popen(
        [str(adapter), str(args.image), str(args.debug_map), f"fd:{master}"],
        pass_fds=(master,),
    )
    os.close(master)
    try:
        command = [str(frontend), "--windows", "--debug-map", str(args.debug_map)]
        command.extend(args.te_args)
        command.append(slave_name)
        return subprocess.call(command)
    finally:
        os.close(slave)
        if proc.poll() is None:
            proc.send_signal(signal.SIGTERM)
        proc.wait()


if __name__ == "__main__":
    sys.exit(main())
