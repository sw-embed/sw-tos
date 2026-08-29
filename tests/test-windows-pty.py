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
import threading
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


class _Drain:
    """Continuously read one pseudo-terminal master into a pending buffer.

    The frontend is single threaded: it writes the rendered screen to its
    terminal and protocol frames to its serial device from the same loop. A
    harness that reads only the descriptor it is currently asserting on lets
    the other pseudo-terminal fill, which blocks the frontend inside write()
    and stalls both streams. Linux hides this because its pseudo-terminals
    buffer about 8 KiB; a rendered four-pane screen exceeds the roughly 1 KiB
    a Darwin pseudo-terminal holds, so the frontend deadlocks there. Draining
    every master continuously keeps the frontend running on both platforms.

    Two further Darwin behaviors shape this reader. A master read reports EIO
    whenever no process holds the slave, which includes the window between the
    harness closing its own slave descriptor and the frontend opening the
    slave by name, so EIO is retried rather than treated as end of stream. And
    select() can report a master readable spuriously, so the descriptor is
    non-blocking and EAGAIN is retried.

    The reader owns a duplicate descriptor so a test closing the original
    cannot make this thread read from a recycled descriptor number. stop()
    releases that duplicate, which is required before a test closes a master
    to make the frontend observe the hangup.
    """

    def __init__(self, fd: int):
        self.fd = os.dup(fd)
        fcntl.fcntl(self.fd, fcntl.F_SETFL,
                    fcntl.fcntl(self.fd, fcntl.F_GETFL) | os.O_NONBLOCK)
        self.buffer = bytearray()
        self.lock = threading.Lock()
        self.done = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self) -> None:
        try:
            while not self.done.is_set():
                try:
                    ready, _, _ = select.select([self.fd], [], [], 0.05)
                    if not ready:
                        continue
                    data = os.read(self.fd, 65536)
                except (BlockingIOError, InterruptedError):
                    time.sleep(0.005)
                    continue
                except (OSError, ValueError):
                    # EIO while the slave side is unopened; retry.
                    time.sleep(0.01)
                    continue
                if not data:
                    time.sleep(0.01)
                    continue
                with self.lock:
                    self.buffer.extend(data)
        finally:
            try:
                os.close(self.fd)
            except OSError:
                pass

    def take(self) -> bytes:
        with self.lock:
            data = bytes(self.buffer)
            del self.buffer[:]
            return data

    def stop(self) -> None:
        self.done.set()
        self.thread.join(timeout=1.0)


_drains: dict[int, _Drain] = {}


def watch(fd: int) -> int:
    """Start draining a freshly opened pseudo-terminal master."""
    _drains[fd] = _Drain(fd)
    return fd


def close_watched(fd: int) -> None:
    """Stop draining a master and close it, so the peer observes the hangup."""
    drain = _drains.pop(fd, None)
    if drain is not None:
        drain.stop()
    os.close(fd)


def read_until(fd: int, needle: bytes, timeout: float = 3.0) -> bytes:
    drain = _drains.get(fd)
    if drain is None:
        watch(fd)
        drain = _drains[fd]
    data = bytearray()
    deadline = time.monotonic() + timeout
    while True:
        data.extend(drain.take())
        if needle in data or time.monotonic() >= deadline:
            return bytes(data)
        time.sleep(0.01)


def start_frontend(session=None):
    terminal_master, terminal_slave = pty.openpty()
    serial_master, serial_slave = pty.openpty()
    watch(terminal_master)
    watch(serial_master)
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


def negotiation_clock_path():
    terminal_master, terminal_slave = pty.openpty()
    serial_master, serial_slave = pty.openpty()
    watch(terminal_master)
    watch(serial_master)
    before = termios.tcgetattr(terminal_slave)
    fcntl.ioctl(terminal_slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))

    def controlling_terminal():
        os.setsid()
        fcntl.ioctl(terminal_slave, termios.TIOCSCTTY, 0)

    process = subprocess.Popen(
        [str(BINARY), "--windows", "--debug-map", str(debug_map_path()), os.ttyname(serial_slave)],
        stdin=terminal_slave,
        stdout=terminal_slave,
        stderr=subprocess.PIPE,
        pass_fds=(terminal_slave,),
        preexec_fn=controlling_terminal,
    )
    os.close(serial_slave)
    # Withhold HELLO_ACK as a hostile-running target would. The frontend must
    # keep supplying IRQ heartbeats and retry HELLO so negotiation can recover.
    #
    # Anchor the observation window on the first HELLO instead of on process
    # start. How long the frontend takes to launch and open both devices says
    # nothing about the retry behavior under test, and on a loaded machine it
    # can consume most of a window measured from Popen.
    assert HELLO in read_until(serial_master, HELLO, 5.0), "frontend never sent HELLO"
    pending = read_until(serial_master, b"never-present", 0.65)
    assert HELLO in pending, "HELLO was not retried during negotiation"
    assert pending.count(b"\xff\x01") >= 10, "scheduler clock stopped before HELLO_ACK"
    os.write(serial_master, ACK)
    identity_request = frame(9, 0, b"\x01")
    assert identity_request in read_until(serial_master, identity_request), "late ACK did not recover"
    os.write(tty_master := terminal_master, b"\x01d")
    assert_restored(process, tty_master, terminal_slave, before, 0)
    close_watched(serial_master)
    close_watched(terminal_master)
    os.close(terminal_slave)


def terminal_attributes(terminal_master, terminal_slave):
    """Read the pseudo-terminal's attributes after the frontend has exited.

    Darwin revokes every descriptor for a controlling terminal when its
    session leader exits, so the slave descriptor stops answering tcgetattr
    even though the terminal still exists. The master mirrors the same
    attributes and survives the revoke, so it is the fallback. Linux does not
    revoke, and keeps using the slave.
    """
    try:
        return termios.tcgetattr(terminal_slave)
    except termios.error:
        return termios.tcgetattr(terminal_master)


def assert_restored(process, terminal_master, terminal_slave, before, expected_status):
    status = process.wait(timeout=3)
    output = read_until(terminal_master, b"\x1b[?1049l", 1.0)
    after = terminal_attributes(terminal_master, terminal_slave)
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
        bytes((6, generation, 2, 11, 0, 0, 42, 0, 0)),
        bytes((5, generation, 2, 0, 0, 8, 0, 0, 9, 0, 0)),
    )
    os.write(serial_master, b"".join(frame(8, 0, record) for record in records))
    os.write(serial_master, frame(2, 0, b"shell-one\nshell-two\n"))
    os.write(serial_master, frame(2, 1, b"app-one\n"))
    screen = read_until(tty_master, b"cntr ep=2", 2.0)
    screen += read_until(tty_master, b"app-one", 2.0)
    assert b"\x1b[?1049h" in screen and b"\x1b[?25l" in screen, "screen entry"
    assert b"Shell *" in screen and b"Application" in screen, "four-pane grid was not rendered"
    assert b"shell-two" in screen and b"app-one" in screen, "independent pane output missing"
    assert b"stk 10/20B" in screen and b"cntr ep=2" in screen, "resource snapshot missing"
    damaged = bytearray(frame(2, 0, b"damaged"))
    damaged[-1] ^= 0x80
    os.write(serial_master, damaged)
    assert b"BadChecksum" in read_until(tty_master, b"BadChecksum"), "decode error missing"
    os.write(serial_master, frame(2, 0, b"recovered\n"))
    recovered = read_until(tty_master, b" ok", 2.0)
    assert b"recovered" in recovered and b" ok" in recovered, "valid frame did not clear error"
    os.write(tty_master, b"\x014\x01z")
    resource_zoom = read_until(tty_master, b"cpu=42", 2.0)
    assert b"fp=11" in resource_zoom and b"cpu=42" in resource_zoom, "preemption activity missing"
    os.write(tty_master, b"\x01z\x011")

    time_generation = 4
    time_records = (
        bytes((1, time_generation)),
        bytes((2, time_generation, 10, 0, 0, 20, 0, 0, 3, 0, 0, 1, 0, 0, 2, 3)),
        bytes((3, time_generation, 2, 7, 1, 192, 0, 1, 0, 9, 0, 0, 4, 0, 0)),
        bytes((4, time_generation, 2, 3, 0, 0, 5, 0, 0, 6, 0, 0)) + b"upti",
        bytes((6, time_generation, 2, 0, 0, 0, 0, 0, 0)),
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
    # Escape is not printable, so it must still be named in the pane it was
    # sent to; otherwise the key is indistinguishable from a dead one.
    os.write(tty_master, b"\x1b")
    assert b"Esc" in read_until(tty_master, b"Esc"), "Escape was not echoed locally"
    assert frame(1, 0, b"\x1b") in read_until(serial_master, frame(1, 0, b"\x1b")), (
        "Escape did not reach the target"
    )

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
    assert b"Application" in resized and b"mon" in resized, "resize/focus render"
    os.write(tty_master, b"\x01z\x01?\x01?\x01z")
    time.sleep(0.1)
    os.write(tty_master, b"\x01d")
    assert_restored(process, tty_master, tty_slave, before, 0)
    close_watched(serial_master)
    close_watched(tty_master)
    os.close(tty_slave)

    restored, tty_master, tty_slave, serial_master, before = start_frontend(session)
    assert b"Counter" in read_until(tty_master, b"Counter"), "saved session restore"
    os.write(tty_master, b"\x01d")
    assert_restored(restored, tty_master, tty_slave, before, 0)
    close_watched(serial_master)
    close_watched(tty_master)
    os.close(tty_slave)


def failure_path():
    process, tty_master, tty_slave, serial_master, before = start_frontend()
    close_watched(serial_master)
    assert_restored(process, tty_master, tty_slave, before, 1)
    close_watched(tty_master)
    os.close(tty_slave)


def copy_mode_interrupt_path():
    process, tty_master, tty_slave, serial_master, before = start_frontend()
    os.write(tty_master, b"\x01y\x03")
    assert_restored(process, tty_master, tty_slave, before, 0)
    close_watched(serial_master)
    close_watched(tty_master)
    os.close(tty_slave)


def main() -> int:
    negotiation_clock_path()
    normal_path()
    failure_path()
    copy_mode_interrupt_path()
    print("PASS: frontend negotiates under clock load, routes, restores sessions, alerts, and guards broadcast")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, subprocess.TimeoutExpired) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
