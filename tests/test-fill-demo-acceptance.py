#!/usr/bin/env python3
"""Menu 9 acceptance: a full process table stays live under two cpu-hogs.

The fill demo spawns two hostile CPU loops and then fills every remaining
process-table slot with clocks and uptimes. Those apps advance only when a
time frame reaches their own TTY ring, and the hogs never yield, so a run
that keeps all of them printing exercises three things at once: the tick
reaching every matching process rather than the foreground one, forced
preemption holding under two non-cooperative children, and the shell staying
responsive enough to answer a command afterwards.
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

#: Slots the demo fills, and the clock and uptime children among them.
SLOTS = 16
HOGS = 2
TIME_APPS = SLOTS - HOGS - 1  # less the shell and the hogs
#: Distinct printed times each of those children must reach.
TICKS = 3


def frame(kind: int, payload: bytes = b"", channel: int = 0) -> bytes:
    header = bytes((1, kind, channel, len(payload) & 255, len(payload) >> 8))
    body = header + payload
    return SYNC + body + bytes((sum(body) & 255,))


class Transport:
    def __init__(self, fd: int):
        self.fd = fd
        self.pending = b""

    def send(self, kind: int, payload: bytes = b"", channel: int = 0):
        os.write(self.fd, frame(kind, payload, channel))

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
                self.pending += os.read(self.fd, 4096)
        return None


def heartbeat(transport: Transport, tick: int):
    # Kind FE is a test-adapter command that injects its payload without SWT
    # framing, matching the hardware frontend's out-of-band UART heartbeat.
    # It is also what drives forced preemption of the hogs.
    transport.send(
        0xFE, bytes((0xFF, 1, tick & 255, tick >> 8 & 255, tick >> 16 & 255))
    )
    time.sleep(0.015)


def type_line(transport: Transport, text: bytes):
    for byte in text:
        transport.send(1, bytes((byte,)), 0)
        time.sleep(0.005)


def forced_counts(transport: Transport, tick: int):
    """Endpoint -> forced-preemption count, for every process that has one.

    Each slot reports a count and only a forcibly preempted one reports a
    non-zero count, so the snapshot both finds the hogs and shows what the
    scheduler is doing to them. A generation covering fewer than the whole
    table began before the request; start over on it.
    """
    transport.send(8)
    counts: dict[int, int] = {}
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
        if payload[0] == 6 and len(payload) == 9:
            counts[payload[2]] = int.from_bytes(payload[3:6], "little")
        elif payload[0] == 5:
            if len(counts) >= SLOTS:
                return tick, counts
            counts.clear()
    raise AssertionError(f"no complete resource generation; saw {counts}")


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
    try:
        transport.send(12, b"SWT1")
        assert transport.receive() == (13, 0, b"SWT1"), "adapter did not greet"
        type_line(transport, b"9\r")

        output: dict[int, bytearray] = {}
        tick = 1
        for round_index in range(420):
            heartbeat(transport, tick)
            tick += 1
            # Both kinds of tick go out together, about once a second: a clock
            # ignores the uptime frame and vice versa, so sending one kind
            # would leave half the table silent.
            if round_index % 20 == 19:
                payload = bytes((tick & 255, tick >> 8 & 255, 0))
                transport.send(6, payload)
                transport.send(7, payload)
            while True:
                received = transport.receive(0.01)
                if received is None:
                    break
                kind, channel, payload = received
                if kind == 2:
                    output.setdefault(channel, bytearray()).extend(payload)

        shell = bytes(output.get(0, b"")).decode("ascii", "replace")
        assert f"{SLOTS} RUNNABLE" in shell, f"table did not fill:\n{shell}"
        assert shell.rstrip().endswith("Choice:"), f"shell left its prompt:\n{shell}"

        advancing = []
        for channel, raw in sorted(output.items()):
            if channel == 0:
                continue
            lines = bytes(raw).decode("ascii", "replace").split("\n")
            times = {line for line in lines if line[:1].isdigit()}
            if len(times) >= TICKS:
                advancing.append(channel)
        assert len(advancing) >= TIME_APPS, (
            f"only {len(advancing)} of {TIME_APPS} time apps reached {TICKS} ticks; "
            f"channels={advancing}"
        )
        tick, first = forced_counts(transport, tick)
        for _ in range(10):
            heartbeat(transport, tick)
            tick += 1
        _, second = forced_counts(transport, tick)
        preempted = {endpoint: count for endpoint, count in first.items() if count}
        assert len(preempted) == HOGS, f"expected {HOGS} preempted hogs, saw {first}"
        for endpoint, count in preempted.items():
            assert second[endpoint] > count, (first, second)

        print(
            f"PASS: {SLOTS} slots filled, {len(advancing)} clocks advanced "
            f"{TICKS}+ ticks each while {HOGS} cpu-hogs were forcibly preempted "
            f"(endpoints {sorted(preempted)})"
        )
    finally:
        os.close(slave)
        if proc.poll() is None:
            proc.terminate()
            proc.wait()


if __name__ == "__main__":
    main()
