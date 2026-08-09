#!/usr/bin/env python3
"""Interactive SWTOS terminal with a UART heartbeat source for Clock."""

import os
import argparse
import pty
import select
import subprocess
import sys
import termios
import time
import tty


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EMU = os.path.join(ROOT, "tools", "bin", "cor24-emu")
DEFAULT_IMAGE = os.path.join(ROOT, "build", "system.bin")
CTRL_RIGHT_BRACKET = 0x1D
APP_ESCAPE = 0x1B


def filter_menu_input(byte: int, menu_prompt: bool, discard_newline: bool):
    """Drop the optional line ending typed after a numeric menu choice."""
    if discard_newline and byte in (ord("\r"), ord("\n")):
        return None, True
    if discard_newline:
        discard_newline = False
    if menu_prompt and byte in b"0123":
        discard_newline = True
    return byte, discard_newline


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", default=DEFAULT_IMAGE)
    args = parser.parse_args()
    image = os.path.abspath(args.image)
    command = [
        EMU,
        "--load-binary",
        f"{image}@0",
        "--entry",
        "0",
        "--terminal",
        "--speed",
        "0",
        "-t",
        "3600",
    ]
    child_master, child_slave = pty.openpty()
    child = subprocess.Popen(
        command,
        stdin=child_slave,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        bufsize=0,
    )
    os.close(child_slave)
    assert child.stdout is not None

    stdin_fd = sys.stdin.fileno()
    stdout_fd = child.stdout.fileno()
    old_tty = None
    if os.isatty(stdin_fd):
        old_tty = termios.tcgetattr(stdin_fd)
        tty.setraw(stdin_fd)

    clock_active = False
    clock_started = 0.0
    menu_prompt = False
    discard_menu_newline = False
    output_tail = b""
    next_heartbeat = time.monotonic()
    try:
        while child.poll() is None:
            timeout = max(0.0, next_heartbeat - time.monotonic()) if clock_active else 0.1
            readable, _, _ = select.select([stdin_fd, stdout_fd], [], [], timeout)

            if stdout_fd in readable:
                data = os.read(stdout_fd, 4096)
                if not data:
                    break
                os.write(sys.stdout.fileno(), data)
                output_tail = (output_tail + data)[-64:]
                if b"Choice: " in output_tail:
                    menu_prompt = True

            if stdin_fd in readable:
                data = os.read(stdin_fd, 64)
                for byte in data:
                    byte, discard_menu_newline = filter_menu_input(
                        byte, menu_prompt, discard_menu_newline
                    )
                    if byte is None:
                        continue
                    if clock_active and byte == CTRL_RIGHT_BRACKET:
                        os.write(child_master, bytes([APP_ESCAPE]))
                        clock_active = False
                    else:
                        os.write(child_master, bytes([byte]))
                        if menu_prompt and byte == ord("3"):
                            clock_active = True
                            clock_started = time.monotonic()
                            next_heartbeat = time.monotonic()
                        if menu_prompt:
                            menu_prompt = False

            now = time.monotonic()
            if clock_active and now >= next_heartbeat:
                elapsed_seconds = int(now - clock_started)
                tick = (elapsed_seconds * 100) & 0xFFFFFF
                payload = bytearray()
                for byte in (tick & 0xFF, (tick >> 8) & 0xFF, (tick >> 16) & 0xFF):
                    if byte == 0xFF:
                        payload.extend((0xFF, 0x00))
                    elif byte == CTRL_RIGHT_BRACKET:
                        payload.extend((0xFF, 0x03))
                    else:
                        payload.append(byte)
                frame = bytes([0xFF, 0x01]) + bytes(payload)
                os.write(child_master, frame)
                next_heartbeat += 1.0
                if next_heartbeat < now - 0.1:
                    next_heartbeat = now + 1.0
    finally:
        if old_tty is not None:
            termios.tcsetattr(stdin_fd, termios.TCSADRAIN, old_tty)
        if child.poll() is None:
            child.terminate()
        child.wait()
        os.close(child_master)
    return child.returncode or 0


if __name__ == "__main__":
    raise SystemExit(main())
