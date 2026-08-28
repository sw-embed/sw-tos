#!/usr/bin/env python3
"""Run the SWTOS window frontend against the tracked COR24 emulator adapter."""

import argparse
import datetime
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
    parser.add_argument(
        "--log",
        type=pathlib.Path,
        help="session log path (default: build/logs/emulator-debug-<timestamp>.log)",
    )
    parser.add_argument("te_args", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parent.parent
    adapter = root / "build/cor24-debugger/swtos-cor24-debug-adapter"
    frontend = root / "tools/te-rs/target/release/te-rs"
    for artifact in (adapter, frontend, args.image, args.debug_map):
        if not artifact.exists():
            parser.error(f"missing {artifact}")

    # The frontend owns the alternate screen and this script terminates the
    # adapter as soon as the frontend exits, so anything either process wrote
    # to the terminal is erased on restore. Send both to a log instead, and
    # name it on failure, so a crash leaves evidence behind.
    log_path = args.log
    if log_path is None:
        stamp = datetime.datetime.now().strftime("%Y%m%dT%H%M%S")
        log_path = root / "build" / "logs" / f"emulator-debug-{stamp}.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)

    master, slave = pty.openpty()
    tty.setraw(slave)
    os.set_blocking(master, False)
    slave_name = os.ttyname(slave)
    with open(log_path, "wb", buffering=0) as log:
        log.write(f"image: {args.image}\n".encode())
        log.write(f"debug map: {args.debug_map}\n".encode())
        log.write(f"adapter pty: {slave_name}\n".encode())
        proc = subprocess.Popen(
            [str(adapter), str(args.image), str(args.debug_map), f"fd:{master}"],
            pass_fds=(master,),
            stdout=log,
            stderr=log,
        )
        os.close(master)
        try:
            command = [str(frontend), "--windows", "--debug-map", str(args.debug_map)]
            command.extend(args.te_args)
            command.append(slave_name)
            status = subprocess.call(command, stdout=log, stderr=log)
        finally:
            os.close(slave)
            if proc.poll() is None:
                proc.send_signal(signal.SIGTERM)
            adapter_status = proc.wait()
        log.write(f"frontend exit: {status}\n".encode())
        log.write(f"adapter exit: {adapter_status}\n".encode())

    if status != 0 or adapter_status not in (0, -signal.SIGTERM):
        print(f"session log: {log_path}", file=sys.stderr)
        for line in log_path.read_text(errors="replace").splitlines()[-12:]:
            print(f"  {line}", file=sys.stderr)
    return status


if __name__ == "__main__":
    sys.exit(main())
