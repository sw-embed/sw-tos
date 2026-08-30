#!/usr/bin/env python3
"""Every process except the shell can be killed from the debugger.

The kill path was built for the forced-preemption proof and only accepted
the first two child slots, and only a process the interrupt handler could
reach. A clock or an uptime never spins, so it is never the process the
handler interrupts and no amount of waiting made it killable: the debugger
answered "status 3" forever. This drives the shell the way a person does,
spawns one of each kind, and requires the slot to come back.
"""

import os
import pathlib
import pty
import select
import subprocess
import time
import tty

ROOT = pathlib.Path(__file__).resolve().parent.parent
IMAGE = ROOT / "build/scheduled-shell/program.bin"
MAP = ROOT / "build/scheduled-shell/program.debug.json"
ADAPTER = ROOT / "build/cor24-debugger/swtos-cor24-debug-adapter"
SYNC = b"\xa5\x5a"

KILL_OK = 0
KILL_REJECTED = 1


def frame(kind: int, payload: bytes = b"", channel: int = 0) -> bytes:
    header = bytes((1, kind, channel, len(payload) & 255, len(payload) >> 8))
    body = header + payload
    return SYNC + body + bytes((sum(body) & 255,))


class Transport:
    def __init__(self, fd: int):
        self.fd = fd
        os.set_blocking(fd, False)
        self.pending = b""

    def send(self, kind: int, payload: bytes = b"", channel: int = 0):
        """Write a frame, reading the target while it will not accept more.

        A full process table out-talks any caller that drains on its own
        cadence: the pseudo-terminal fills and the next write blocks forever,
        which stalls the very loop that would have emptied it. Draining on
        EAGAIN makes the deadlock impossible regardless of how much the target
        has to say.
        """
        data = frame(kind, payload, channel)
        deadline = time.monotonic() + 10
        while data:
            try:
                data = data[os.write(self.fd, data):]
            except BlockingIOError:
                if time.monotonic() > deadline:
                    raise AssertionError("target stopped reading its transport")
                ready, _, _ = select.select([self.fd], [], [], 0.02)
                if ready:
                    try:
                        self.pending += os.read(self.fd, 65536)
                    except BlockingIOError:
                        pass

    def receive(self, timeout: float = 5.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            pos = self.pending.find(SYNC)
            if pos >= 0 and len(self.pending) >= pos + 8:
                length = self.pending[pos + 5] | self.pending[pos + 6] << 8
                end = pos + length + 8
                if len(self.pending) >= end:
                    data = self.pending[pos:end]
                    self.pending = self.pending[end:]
                    assert sum(data[2:-1]) & 255 == data[-1]
                    return data[3], data[4], data[7:-1]
            ready, _, _ = select.select(
                [self.fd], [], [], max(0, deadline - time.monotonic())
            )
            if ready:
                try:
                    self.pending += os.read(self.fd, 65536)
                except BlockingIOError:
                    continue
        return None


def heartbeat(transport: Transport, tick: int):
    transport.send(0xFE, bytes((0xFF, 1, tick & 255, tick >> 8 & 255, tick >> 16 & 255)))
    time.sleep(0.015)


def type_line(transport: Transport, text: bytes):
    for byte in text:
        transport.send(1, bytes((byte,)), 0)
        time.sleep(0.006)


def pump(transport: Transport, tick: int, rounds: int, output: dict):
    for _ in range(rounds):
        heartbeat(transport, tick)
        tick += 1
        while True:
            received = transport.receive(0.01)
            if received is None:
                break
            kind, channel, payload = received
            if kind == 2:
                output.setdefault(channel, bytearray()).extend(payload)
    return tick


def kill(transport: Transport, tick: int, endpoint: int):
    transport.send(9, bytes((0x0D, endpoint)))
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        heartbeat(transport, tick)
        tick += 1
        received = transport.receive(0.05)
        if received is not None and received[0] == 10 and received[2][:2] == bytes((0x0D, endpoint)):
            return tick, received[2][2]
    raise AssertionError(f"no kill answer for endpoint {endpoint}")


def slot_states(transport: Transport, tick: int):
    """Endpoint -> process state, from one complete resource generation."""
    transport.send(8)
    states = {}
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        heartbeat(transport, tick)
        tick += 1
        received = transport.receive(0.05)
        if received is None:
            continue
        kind, _, payload = received
        if kind != 8 or len(payload) < 2:
            continue
        # A record is [kind, generation, body...]; kind 3 is one process.
        if payload[0] == 3 and len(payload) == 15:
            states[payload[2]] = payload[3]
        elif payload[0] == 5:                        # end of generation
            if states:
                return tick, states
            states.clear()
    raise AssertionError("no complete resource generation")


def main():
    for artifact in (IMAGE, MAP, ADAPTER):
        assert artifact.exists(), f"missing {artifact}; run documented build recipes"

    master, slave = pty.openpty()
    tty.setraw(slave)
    os.set_blocking(master, False)
    proc = subprocess.Popen(
        [str(ADAPTER), str(IMAGE), str(MAP), f"fd:{master}"],
        pass_fds=(master,), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    os.close(master)
    transport = Transport(slave)
    output: dict[int, bytearray] = {}
    try:
        transport.send(12, b"SWT1")
        assert transport.receive() == (13, 0, b"SWT1"), "adapter did not greet"

        # The monitor starts itself when a frontend attaches, with nothing
        # typed. Nothing at boot can know one is coming, so the kernel wakes
        # the shell on HELLO and the shell runs its startup list.
        tick = pump(transport, tick_start := 1, 200, output)
        assert tick_start == 1
        tick, booted = slot_states(transport, tick)
        assert booted.get(2), f"the monitor did not start itself: {booted}"
        assert b"mon" in bytes(output.get(1, b"")), (
            f"the monitor produced nothing: {bytes(output.get(1, b''))!r}")

        for command in (b"run clock --tty=new\r", b"run uptime --tty=new\r",
                        b"run cpu-hog --tty=new\r"):
            type_line(transport, command)
            tick = pump(transport, tick, 60, output)

        tick, before = slot_states(transport, tick)
        live = sorted(endpoint for endpoint, state in before.items()
                      if endpoint != 1 and state)
        assert len(live) >= 3, f"expected three children, saw {before}"

        # The shell is protected; everything else goes.
        tick, status = kill(transport, tick, 1)
        assert status == KILL_REJECTED, f"shell was killable: status {status}"

        killed = []
        for endpoint in live[:3]:
            tick, status = kill(transport, tick, endpoint)
            assert status == KILL_OK, f"endpoint {endpoint} refused: status {status}"
            killed.append(endpoint)
            tick = pump(transport, tick, 40, output)

        tick, after = slot_states(transport, tick)
        still_live = [endpoint for endpoint in killed if after.get(endpoint)]
        assert not still_live, f"still running after kill: {still_live} ({after})"
        assert after.get(1), f"the shell did not survive: {after}"

        # The shell kills through the same kernel routine, so a person can
        # start and stop processes without switching panes, and the slot a
        # kill frees is the one the next run takes.
        type_line(transport, b"run mon\r")
        tick = pump(transport, tick, 60, output)
        tick, started = slot_states(transport, tick)
        reused = sorted(endpoint for endpoint, state in started.items()
                        if endpoint != 1 and state)
        assert reused, f"shell run started nothing: {started}"

        # The "ep=N" spelling the monitor and ps display must be typeable
        # back exactly as it appears on screen.
        type_line(transport, b"kill ep=%d\r" % reused[0])
        tick = pump(transport, tick, 60, output)
        tick, after_shell_kill = slot_states(transport, tick)
        assert not after_shell_kill.get(reused[0]), (
            f"shell kill left endpoint {reused[0]} running: {after_shell_kill}")

        type_line(transport, b"run mon\r")
        tick = pump(transport, tick, 60, output)
        tick, restarted = slot_states(transport, tick)
        assert restarted.get(reused[0]), (
            f"the freed slot was not reused: {restarted}")

        print(f"PASS: debugger killed endpoints {killed} and refused the shell; "
              f"the shell killed endpoint {reused[0]} and reused its slot")
    finally:
        os.close(slave)
        if proc.poll() is None:
            proc.terminate()
            proc.wait()


if __name__ == "__main__":
    main()
