#!/usr/bin/env python3
"""Interactive SWTOS terminal with uptime and wall-clock frames."""

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
EMU = os.path.join(ROOT, "scripts", "swtos-emu")
DEFAULT_IMAGE = os.path.join(ROOT, "build", "system.bin")
CTRL_RIGHT_BRACKET = 0x1D
APP_ESCAPE = 0x1B


def filter_menu_input(byte: int, menu_prompt: bool, discard_newline: bool):
    """Drop the optional line ending typed after a numeric menu choice."""
    if discard_newline and byte in (ord("\r"), ord("\n")):
        return None, True
    if discard_newline:
        discard_newline = False
    if menu_prompt and byte in b"01234":
        discard_newline = True
    return byte, discard_newline


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", default=DEFAULT_IMAGE)
    parser.add_argument("--lgo-seed")
    parser.add_argument("--spi-media")
    parser.add_argument("--sd-media")
    args = parser.parse_args()
    image = os.path.abspath(args.image)
    command = [EMU]
    if args.lgo_seed:
        command.extend(["--lgo", os.path.abspath(args.lgo_seed)])
    command.extend([
        "--load-binary", f"{image}@0",
        "--entry",
        "0",
        "--terminal",
        "--speed",
        "0",
        "-t",
        "3600",
    ])
    if args.spi_media:
        command.extend([
            "--spi-device",
            f"w25q32@cs=3?file={os.path.abspath(args.spi_media)}",
        ])
    if args.sd_media:
        command.extend([
            "--spi-device",
            f"sdcard@cs=2?file={os.path.abspath(args.sd_media)}",
        ])
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

    time_mode = None
    connection_started = time.monotonic()
    menu_prompt = False
    discard_menu_newline = False
    output_tail = b""
    input_line = bytearray()
    next_heartbeat = time.monotonic()
    try:
        while child.poll() is None:
            timeout = max(0.0, next_heartbeat - time.monotonic()) if time_mode else 0.1
            readable, _, _ = select.select([stdin_fd, stdout_fd], [], [], timeout)

            if stdout_fd in readable:
                data = os.read(stdout_fd, 4096)
                if not data:
                    break
                os.write(sys.stdout.fileno(), data)
                combined = output_tail + data
                if b"# " in combined:
                    menu_prompt = True
                    time_mode = None
                output_tail = combined[-7:]

            if stdin_fd in readable:
                data = os.read(stdin_fd, 64)
                for byte in data:
                    byte, discard_menu_newline = filter_menu_input(
                        byte, menu_prompt, discard_menu_newline
                    )
                    if byte is None:
                        continue
                    if time_mode and byte == CTRL_RIGHT_BRACKET:
                        os.write(child_master, bytes([APP_ESCAPE]))
                        time_mode = None
                    else:
                        os.write(child_master, bytes([byte]))
                        if menu_prompt and byte not in (ord("\r"), ord("\n")):
                            input_line.append(byte)
                        if menu_prompt and byte in (ord("\r"), ord("\n")):
                            command = bytes(input_line).strip().lower()
                            if command == b"run uptime":
                                time_mode = "uptime"
                                next_heartbeat = time.monotonic()
                            elif command == b"run clock":
                                time_mode = "clock"
                                next_heartbeat = time.monotonic()
                            input_line.clear()
                            menu_prompt = False
                        if menu_prompt and byte == ord("3"):
                            time_mode = "uptime"
                            next_heartbeat = time.monotonic()
                        elif menu_prompt and byte == ord("4"):
                            time_mode = "clock"
                            next_heartbeat = time.monotonic()
                        if menu_prompt and byte in b"01234":
                            menu_prompt = False

            now = time.monotonic()
            if time_mode and now >= next_heartbeat:
                if time_mode == "uptime":
                    tick = int((now - connection_started) * 100) & 0xFFFFFF
                    frame_code = 1
                else:
                    wall = time.time()
                    local = time.localtime(wall)
                    tick = (((local.tm_hour * 3600 + local.tm_min * 60 + local.tm_sec) * 100
                            + int((wall % 1) * 100)) & 0xFFFFFF)
                    frame_code = 2
                payload = bytearray()
                for byte in (tick & 0xFF, (tick >> 8) & 0xFF, (tick >> 16) & 0xFF):
                    if byte == 0xFF:
                        payload.extend((0xFF, 0x00))
                    elif byte == CTRL_RIGHT_BRACKET:
                        payload.extend((0xFF, 0x03))
                    else:
                        payload.append(byte)
                frame = bytes([0xFF, frame_code]) + bytes(payload)
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
