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


def start_frontend(session=None):
    terminal_master, terminal_slave = pty.openpty()
    serial_master, serial_slave = pty.openpty()
    before = termios.tcgetattr(terminal_slave)
    fcntl.ioctl(terminal_slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))

    def controlling_terminal():
        os.setsid()
        fcntl.ioctl(terminal_slave, termios.TIOCSCTTY, 0)

    command = [str(BINARY), "--windows", "--prefix", "^A", "--debug-map", str(debug_map_path())]
    if session is not None:
        command.extend(("--session", str(session)))
    command.append(os.ttyname(serial_slave))
    process = subprocess.Popen(
        command,
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
    session = ROOT / "build/windows-pty/session.json"
    session.unlink(missing_ok=True)
    process, tty_master, tty_slave, serial_master, before = start_frontend(session)
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

    time_generation = 4
    time_records = (
        bytes((1, time_generation)),
        bytes((2, time_generation, 10, 0, 0, 20, 0, 0, 3, 0, 0, 1, 0, 0, 2, 3)),
        bytes((3, time_generation, 2, 7, 1, 192, 0, 1, 0, 9, 0, 0, 4, 0, 0)),
        bytes((4, time_generation, 2, 3, 0, 0, 5, 0, 0, 6, 0, 0)) + b"upti",
        bytes((5, time_generation, 2, 0, 0, 8, 0, 0, 9, 0, 0)),
    )
    os.write(serial_master, b"".join(frame(8, 0, record) for record in time_records))
    uptime_frame_prefix = SYNC + bytes((1, 6, 0, 3, 0))
    time_traffic = read_until(serial_master, uptime_frame_prefix, 2.0)
    assert uptime_frame_prefix in time_traffic, "live Uptime did not enable host time frames"
    assert SYNC + bytes((1, 7, 0, 3, 0)) not in time_traffic, "Uptime received wall-clock frames"

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
    os.write(tty_master, b"ps\r")
    assert b"ps" in read_until(tty_master, b"ps"), "shell local input echo"
    shell_command = read_until(serial_master, frame(1, 0, b"\n"))
    assert frame(1, 0, b"p") in shell_command
    assert frame(1, 0, b"s") in shell_command
    assert frame(1, 0, b"\n") in shell_command, "shell Enter was not normalized"
    assert frame(1, 0, b"\r") not in shell_command, "shell received carriage return"
    os.write(tty_master, b"\x012b")
    assert frame(1, 1, b"b") in read_until(serial_master, frame(1, 1, b"b")), "app input route"
    os.write(tty_master, b"\x01y\x01e")
    target_escape = frame(1, 1, b"\x1b")
    assert target_escape in read_until(serial_master, target_escape), "target Escape from copy mode"
    os.write(tty_master, b"\x01y")

    os.write(serial_master, frame(3, 2, b"Counter"))
    assert b"Counter *" in read_until(tty_master, b"Counter *"), "dynamic channel open"
    os.write(tty_master, b"\x011")
    assert b"Shell *" in read_until(tty_master, b"Shell *"), "focus before background output"
    os.write(serial_master, frame(2, 2, b"count 1\n"))
    assert b"Counter !" in read_until(tty_master, b"Counter !"), "background input alert"

    # One broadcast command only arms the dangerous operation. An intervening
    # focus command cancels it, so ordinary input remains exclusive.
    os.write(tty_master, b"\x01b\x011q")
    exclusive = read_until(serial_master, frame(1, 0, b"q"))
    assert frame(1, 0, b"q") in exclusive
    assert frame(1, 1, b"q") not in exclusive and frame(1, 2, b"q") not in exclusive
    os.write(tty_master, b"\x01b\x01bv")
    broadcast = read_until(serial_master, frame(1, 2, b"v"))
    assert all(frame(1, channel, b"v") in broadcast for channel in (0, 1, 2)), "confirmed broadcast"
    os.write(tty_master, b"\x01\x1b")

    os.write(tty_master, b"\x01w")
    deadline = time.monotonic() + 2
    while not session.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    assert session.exists() and b'"channel": 2' in session.read_bytes(), "saved dynamic session"
    os.write(serial_master, frame(4, 2, b""))
    time.sleep(0.1)
    os.write(tty_master, b"\x012")
    read_until(tty_master, b"Application *")

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

    restored, tty_master, tty_slave, serial_master, before = start_frontend(session)
    assert b"Counter" in read_until(tty_master, b"Counter"), "saved session restore"
    os.write(tty_master, b"\x01d")
    assert_restored(restored, tty_master, tty_slave, before, 0)
    os.close(serial_master)
    os.close(tty_master)
    os.close(tty_slave)


def failure_path():
    process, tty_master, tty_slave, serial_master, before = start_frontend()
    os.close(serial_master)
    assert_restored(process, tty_master, tty_slave, before, 1)
    os.close(tty_master)
    os.close(tty_slave)


def copy_mode_interrupt_path():
    process, tty_master, tty_slave, serial_master, before = start_frontend()
    os.write(tty_master, b"\x01y\x03")
    assert_restored(process, tty_master, tty_slave, before, 0)
    os.close(serial_master)
    os.close(tty_master)
    os.close(tty_slave)


def main() -> int:
    normal_path()
    failure_path()
    copy_mode_interrupt_path()
    print("PASS: dynamic PTY frontend routes, restores sessions, alerts, and guards broadcast")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, subprocess.TimeoutExpired) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
