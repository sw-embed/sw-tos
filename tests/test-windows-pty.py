#!/usr/bin/env python3

import fcntl
import json
import os
import pathlib
import pty
import select
import struct
import subprocess
import sys
import termios
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
BINARY = ROOT / "tools/te-rs/target/debug/te-rs"
SYNC = b"\xA5\x5A"
DEBUG_ID = 0x123456


def frame(kind: int, channel: int, payload: bytes) -> bytes:
    header = bytes((1, kind, channel, len(payload) & 0xFF, len(payload) >> 8))
    return SYNC + header + payload + bytes((sum(header + payload) & 0xFF,))


HELLO = frame(12, 0, b"SWT1")
ACK = frame(13, 0, b"SWT1")


def debug_map_path() -> pathlib.Path:
    output = ROOT / "build/windows-pty/program.debug.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({
        "format": "swtos-debug-v1",
        "build_id": f"crc24:{DEBUG_ID:06x}",
        "build_id_size": 32,
        "image_sha256": "00" * 32,
        "image_size": 64,
        "symbols": [{"name": "counter", "address": 16, "module": "app"}],
        "functions": [],
        "instructions": [{
            "address": 16, "size": 2, "bytes": "4401", "text": "lc r0,1",
            "source": "app.s", "line": 7,
        }],
        "variable_locations": [],
    }))
    return output


def read_until(fd: int, needle: bytes, timeout: float = 3.0) -> bytes:
    data = bytearray()
    deadline = time.monotonic() + timeout
    while needle not in data and time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.05)
        if ready:
            try:
                data.extend(os.read(fd, 65536))
            except OSError:
                time.sleep(0.01)
    return bytes(data)


def start_frontend():
    terminal_master, terminal_slave = pty.openpty()
    serial_master, serial_slave = pty.openpty()
    before = termios.tcgetattr(terminal_slave)
    fcntl.ioctl(terminal_slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))

    def controlling_terminal():
        os.setsid()
        fcntl.ioctl(terminal_slave, termios.TIOCSCTTY, 0)

    process = subprocess.Popen(
        [str(BINARY), "--windows", "--prefix", "^A", "--debug-map", str(debug_map_path()), os.ttyname(serial_slave)],
        stdin=terminal_slave,
        stdout=terminal_slave,
        stderr=subprocess.PIPE,
        pass_fds=(terminal_slave,),
        preexec_fn=controlling_terminal,
    )
    os.close(serial_slave)
    greeting = read_until(serial_master, HELLO)
    if HELLO not in greeting:
        status = process.poll()
        try:
            wchan = pathlib.Path(f"/proc/{process.pid}/wchan").read_text().strip()
        except OSError:
            wchan = "unavailable"
        if status is None:
            process.terminate()
            process.wait(timeout=1)
        diagnostic = process.stderr.read().decode(errors="replace")
        terminal = read_until(terminal_master, b"never-present", 0.1)
        raise AssertionError(
            f"frontend did not send HELLO (serial={greeting.hex()}, terminal={terminal.hex()}, status={status}, wchan={wchan}, stderr={diagnostic})"
        )
    os.write(serial_master, ACK)
    identity_request = frame(9, 0, b"\x01")
    requests = read_until(serial_master, identity_request)
    assert identity_request in requests, "debug identity request"
    os.write(serial_master, frame(10, 0, bytes((1, 0x56, 0x34, 0x12))))
    return process, terminal_master, terminal_slave, serial_master, before


def assert_restored(process, terminal_master, terminal_slave, before, expected_status):
    status = process.wait(timeout=3)
    output = read_until(terminal_master, b"\x1b[?1049l", 1.0)
    after = termios.tcgetattr(terminal_slave)
    assert status == expected_status, (status, process.stderr.read().decode(errors="replace"))
    assert b"\x1b[?1049l" in output, "screen restore"
    assert b"\x1b[?25h" in output, "cursor restore"
    assert after == before, "terminal attributes were not restored"


def normal_path():
    process, tty_master, tty_slave, serial_master, before = start_frontend()
    generation = 3
    records = (
        bytes((1, generation)),
        bytes((2, generation, 10, 0, 0, 20, 0, 0, 3, 0, 0, 1, 0, 0, 2, 3)),
        bytes((3, generation, 2, 7, 1, 192, 0, 1, 0, 9, 0, 0, 4, 0, 0)),
        bytes((4, generation, 2, 3, 0, 0, 5, 0, 0, 6, 0, 0)) + b"cntr",
        bytes((5, generation, 2, 0, 0, 8, 0, 0, 9, 0, 0)),
    )
    os.write(serial_master, b"".join(frame(8, 0, record) for record in records))
    os.write(serial_master, frame(2, 0, b"shell-one\nshell-two\n"))
    os.write(serial_master, frame(2, 1, b"app-one\n"))
    screen = read_until(tty_master, b"cntr ep=2", 2.0)
    assert b"\x1b[?1049h" in screen and b"\x1b[?25l" in screen, "screen entry"
    assert b"Shell *" in screen and b"Application" in screen, "four-pane grid was not rendered"
    assert b"shell-two" in screen and b"app-one" in screen, "independent pane output missing"
    assert b"mem 10/20B" in screen and b"cntr ep=2" in screen, "resource snapshot missing"

    os.write(tty_master, b"\x013sym counter\n")
    assert b"counter = 000010" in read_until(tty_master, b"counter = 000010"), "symbol lookup"
    os.write(tty_master, b"regs 2\n")
    register_request = frame(9, 0, bytes((2, 2)))
    assert register_request in read_until(serial_master, register_request), "register request"
    os.write(serial_master, frame(10, 0, bytes((2, 2, 0)) + bytes.fromhex("010000020000030000040000")))
    os.write(serial_master, frame(10, 0, bytes((2, 2, 1)) + bytes.fromhex("100000010000")))
    assert b"pc=000010" in read_until(tty_master, b"pc=000010"), "register display"
    os.write(tty_master, b"x 0 4\n")
    memory_request = frame(9, 0, bytes((3, 0, 0, 0, 4)))
    assert memory_request in read_until(serial_master, memory_request), "memory request"
    os.write(serial_master, frame(10, 0, bytes((3, 0, 0, 0, 0x29, 0, 0xEC, 0xFE))))
    assert b"000000: 29 00 ec fe" in read_until(tty_master, b"000000: 29 00 ec fe"), "memory display"

    os.write(tty_master, b"\x011")
    os.write(tty_master, b"a")
    assert frame(1, 0, b"a") in read_until(serial_master, frame(1, 0, b"a")), "shell input route"
    os.write(tty_master, b"\x012b")
    assert frame(1, 1, b"b") in read_until(serial_master, frame(1, 1, b"b")), "app input route"

    read_until(tty_master, b"never-present", 0.1)
    fcntl.ioctl(tty_slave, termios.TIOCSWINSZ, struct.pack("HHHH", 16, 50, 0, 0))
    resized = read_until(tty_master, b"Application *", 2.0)
    assert b"Application *" in resized and b"Resources" in resized, "resize/focus render"
    os.write(tty_master, b"\x01z\x01?\x01?\x01z")
    time.sleep(0.1)
    os.write(tty_master, b"\x01d")
    assert_restored(process, tty_master, tty_slave, before, 0)
    os.close(serial_master)
    os.close(tty_master)
    os.close(tty_slave)


def failure_path():
    process, tty_master, tty_slave, serial_master, before = start_frontend()
    os.close(serial_master)
    assert_restored(process, tty_master, tty_slave, before, 1)
    os.close(tty_master)
    os.close(tty_slave)


def main() -> int:
    normal_path()
    failure_path()
    print("PASS: four-pane PTY frontend routes focus, resizes, and restores terminal state")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, subprocess.TimeoutExpired) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
