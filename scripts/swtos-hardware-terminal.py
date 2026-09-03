#!/usr/bin/env python3
"""Raw serial terminal for SWTOS, with uptime and wall-clock frames."""

import argparse
import errno
import fcntl
import os
import select
import struct
import sys
import termios
import time
import tty


CTRL_RIGHT_BRACKET = 0x1D
APP_ESCAPE = 0x1B
MENU_PROMPT = b"# "
TIOCM_RTS = 0x004
TIOCMBIS = 0x5416


def time_frame(frame_code: int, tick: int) -> bytes:
    payload = bytearray((0xFF, frame_code))
    for byte in (tick & 0xFF, (tick >> 8) & 0xFF, (tick >> 16) & 0xFF):
        if byte == 0xFF:
            payload.extend((0xFF, 0x00))
        elif byte == CTRL_RIGHT_BRACKET:
            payload.extend((0xFF, 0x03))
        else:
            payload.append(byte)
    return bytes(payload)


def configure_serial(fd: int) -> None:
    attr = termios.tcgetattr(fd)
    attr[0] = 0
    attr[1] = 0
    attr[2] &= ~(termios.PARENB | termios.CSTOPB)
    attr[2] |= termios.CS8 | termios.CLOCAL | termios.CREAD | termios.CRTSCTS
    attr[3] = 0
    attr[4] = termios.B921600
    attr[5] = termios.B921600
    termios.tcsetattr(fd, termios.TCSANOW, attr)
    fcntl.ioctl(fd, TIOCMBIS, struct.pack("i", TIOCM_RTS))


def write_all(fd: int, data: bytes) -> None:
    """Write a complete control frame even when the serial fd is nonblocking."""
    offset = 0
    while offset < len(data):
        try:
            offset += os.write(fd, data[offset:])
        except BlockingIOError:
            select.select([], [fd], [])


def terminal_output(data: bytes, previous_cr: bool) -> tuple[bytes, bool]:
    """Render target LF line endings correctly while preserving any CRLF."""
    rendered = bytearray()
    for byte in data:
        if byte == 0x0A and not previous_cr:
            rendered.append(0x0D)
        rendered.append(byte)
        previous_cr = byte == 0x0D
    return bytes(rendered), previous_cr


def main() -> int:
    parser = argparse.ArgumentParser()
    recovery = parser.add_mutually_exclusive_group()
    recovery.add_argument(
        "--uptime-active",
        action="store_true",
        help="reattach while SWTOS is already waiting inside Uptime",
    )
    recovery.add_argument(
        "--clock-active",
        action="store_true",
        help="reattach while SWTOS is already waiting inside Clock",
    )
    parser.add_argument("device")
    args = parser.parse_args()

    serial_fd = -1
    try:
        serial_fd = os.open(
            args.device, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK
        )
        configure_serial(serial_fd)
    except OSError as error:
        if serial_fd >= 0:
            os.close(serial_fd)
        print(f"swtos-terminal: cannot open {args.device}: {error.strerror}", file=sys.stderr)
        return 1
    stdin_fd = sys.stdin.fileno()
    stdout_fd = sys.stdout.fileno()
    old_tty = termios.tcgetattr(stdin_fd)
    tty.setraw(stdin_fd)

    time_mode = "uptime" if args.uptime_active else "clock" if args.clock_active else None
    mode = f"{time_mode.title()} recovery" if time_mode else "menu"
    notice = (
        f"\r\n[connected to {args.device} at 921600 baud; {mode} mode; "
        "Ctrl-C exits]\r\n"
    )
    os.write(stdout_fd, notice.encode("utf-8"))
    if not time_mode:
        os.write(
            stdout_fd,
            b"[UART output is not replayed; use --uptime-active or "
            b"--clock-active when reattaching inside a time app]\r\n",
        )

    connection_started = time.monotonic()
    next_heartbeat = connection_started
    # A normal use starts by attaching to the already displayed SWTOS menu.
    # Seeing a later Choice prompt refreshes this state in the usual way.
    menu_prompt = not time_mode
    discard_choice_newline = False
    swallow_lf = False
    output_tail = b""
    input_line = bytearray()
    previous_output_cr = False

    try:
        while True:
            now = time.monotonic()
            timeout = max(0.0, next_heartbeat - now) if time_mode else None
            readable, _, _ = select.select([stdin_fd, serial_fd], [], [], timeout)

            if serial_fd in readable:
                try:
                    data = os.read(serial_fd, 4096)
                except BlockingIOError:
                    data = b""
                if data:
                    rendered, previous_output_cr = terminal_output(
                        data, previous_output_cr
                    )
                    os.write(stdout_fd, rendered)
                    combined = output_tail + data
                    if MENU_PROMPT in combined:
                        menu_prompt = True
                        time_mode = None
                    # Retain only enough bytes to recognize a prompt split
                    # between two reads. Keeping the complete old prompt here
                    # would falsely rediscover it on the next target output.
                    output_tail = combined[-(len(MENU_PROMPT) - 1):]

            if stdin_fd in readable:
                data = os.read(stdin_fd, 64)
                for byte in data:
                    if byte == 0x03:
                        return 0
                    if swallow_lf and byte == 0x0A:
                        swallow_lf = False
                        continue
                    swallow_lf = False
                    if byte in (0x0D, 0x0A):
                        os.write(stdout_fd, b"\r\n")
                    elif byte in (CTRL_RIGHT_BRACKET, APP_ESCAPE):
                        os.write(stdout_fd, b"Escape\r\n")
                    elif byte in (0x08, 0x7F):
                        os.write(stdout_fd, b"\b \b")
                    elif 0x20 <= byte < 0x7F:
                        os.write(stdout_fd, bytes((byte,)))
                    if discard_choice_newline and byte in (0x0D, 0x0A):
                        discard_choice_newline = False
                        continue
                    if time_mode and byte in (CTRL_RIGHT_BRACKET, APP_ESCAPE):
                        write_all(serial_fd, bytes((APP_ESCAPE,)))
                        time_mode = None
                        continue
                    if byte == 0x0D:
                        byte = 0x0A
                        swallow_lf = True
                    write_all(serial_fd, bytes((byte,)))
                    if menu_prompt and byte not in (0x0A,):
                        input_line.append(byte)
                    if menu_prompt and byte == 0x0A:
                        command = bytes(input_line).strip().lower()
                        if command == b"run uptime":
                            time_mode = "uptime"
                            next_heartbeat = time.monotonic()
                        elif command == b"run clock":
                            time_mode = "clock"
                            next_heartbeat = time.monotonic()
                        input_line.clear()
                        menu_prompt = False
                    if menu_prompt and byte in b"01234":
                        discard_choice_newline = True
                        if byte == ord("3"):
                            time_mode = "uptime"
                            next_heartbeat = time.monotonic()
                        elif byte == ord("4"):
                            time_mode = "clock"
                            next_heartbeat = time.monotonic()
                    if menu_prompt and byte in b"01234":
                        menu_prompt = False

            now = time.monotonic()
            if time_mode and now >= next_heartbeat:
                if time_mode == "uptime":
                    tick = int((now - connection_started) * 100)
                    frame_code = 1
                else:
                    wall = time.time()
                    local = time.localtime(wall)
                    tick = ((local.tm_hour * 3600 + local.tm_min * 60 + local.tm_sec) * 100
                            + int((wall % 1) * 100))
                    frame_code = 2
                write_all(serial_fd, time_frame(frame_code, tick & 0xFFFFFF))
                next_heartbeat += 1.0
                if next_heartbeat < now - 0.1:
                    next_heartbeat = now + 1.0
    except OSError as error:
        if error.errno not in (errno.EIO, errno.ENODEV, errno.ENXIO, errno.EBADF):
            raise
        os.write(
            stdout_fd,
            f"\r\n[serial device disconnected: {args.device}]\r\n".encode("utf-8"),
        )
        return 1
    finally:
        termios.tcsetattr(stdin_fd, termios.TCSADRAIN, old_tty)
        try:
            os.close(serial_fd)
        except OSError:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
