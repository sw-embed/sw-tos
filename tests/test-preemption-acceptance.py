#!/usr/bin/env python3
"""Hostile CPU-loop acceptance over the real framed emulator transport."""

import os
import json
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

    def debug(self, payload: bytes):
        self.send(9, payload)
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            received = self.receive(0.1)
            if received is not None and received[0] == 10:
                return received[2]
        return None


def u24(value: int) -> bytes:
    return bytes((value & 255, value >> 8 & 255, value >> 16 & 255))


def diagnostic_state(transport: Transport):
    symbols = {
        item["name"]: item["address"]
        for item in json.loads(MAP.read_text())["symbols"]
    }
    result = {"registers": transport.debug(b"\x02\x01")}
    for name in ("_current_proc", "_proc_b_preempt", "_preemption_frame_state"):
        result[name] = transport.debug(b"\x03" + u24(symbols[name]) + b"\x1e")
    return {key: value.hex() if value is not None else None for key, value in result.items()}


def heartbeat(transport: Transport, tick: int):
    # Kind FE is a test-adapter command that injects its payload without SWT
    # framing, matching the hardware frontend's out-of-band UART heartbeat.
    transport.send(
        0xFE, bytes((0xFF, 1, tick & 255, tick >> 8 & 255, tick >> 16 & 255))
    )
    time.sleep(0.015)


def resource_sample(transport: Transport, tick: int):
    transport.send(8)
    latest = None
    observed = []
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        heartbeat(transport, tick)
        tick += 1
        received = transport.receive(0.05)
        if received is None:
            continue
        kind, _, payload = received
        observed.append((kind, payload.hex()))
        if kind != 8 or len(payload) < 2:
            continue
        if payload[0] == 6 and len(payload) == 9 and payload[2] == 2:
            latest = (
                int.from_bytes(payload[3:6], "little"),
                int.from_bytes(payload[6:9], "little"),
            )
        if payload[0] == 5 and latest is not None:
            return tick, latest
    raise AssertionError(
        "resource snapshot did not expose cpu-hog preemption; "
        f"last frames={observed[-20:]}"
    )


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
        assert transport.receive() == (13, 0, b"SWT1")
        for byte in b"run cpu-hog\r":
            transport.send(1, bytes((byte,)), 0)
            time.sleep(0.003)

        tick = 1
        for _ in range(7):
            heartbeat(transport, tick)
            tick += 1
        try:
            tick, first = resource_sample(transport, tick)
        except AssertionError as error:
            raise AssertionError(f"{error}; debug={diagnostic_state(transport)}") from error
        for _ in range(7):
            heartbeat(transport, tick)
            tick += 1
        tick, second = resource_sample(transport, tick)

        assert first[0] > 0, first
        assert second[0] > first[0], (first, second)
        assert second[1] != first[1], (first, second)

        # A debugger request must still complete while the application never
        # yields, blocks, performs IPC, or enters a syscall.
        transport.send(9, b"\x01")
        response = None
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and response is None:
            heartbeat(transport, tick)
            tick += 1
            received = transport.receive(0.05)
            if received is None:
                continue
            kind, _, payload = received
            if kind == 10 and payload[:1] == b"\x01":
                response = payload
        assert response is not None, "debugger stopped responding under cpu-hog"
        print(
            "PASS: cpu-hog advanced under forced preemption "
            f"(forced {first[0]}->{second[0]}, cpu {first[1]}->{second[1]})"
        )
    finally:
        os.close(slave)
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=2)


if __name__ == "__main__":
    main()
