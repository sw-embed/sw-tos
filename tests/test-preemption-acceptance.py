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

    def debug(self, payload: bytes):
        self.send(9, payload)
        prefix = payload[:4] if payload[:1] == b"\x03" else payload[:2]
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            received = self.receive(0.1)
            if (
                received is not None
                and received[0] == 10
                and received[2].startswith(prefix)
            ):
                return received[2]
        return None


def u24(value: int) -> bytes:
    return bytes((value & 255, value >> 8 & 255, value >> 16 & 255))


def diagnostic_state(transport: Transport):
    symbols = {
        item["name"]: item["address"]
        for item in json.loads(MAP.read_text())["symbols"]
    }
    result = {"pause": transport.debug(b"\x04"), "registers": transport.debug(b"\x02\x01")}
    for name in (
        "_current_proc",
        "_proc_a",
        "_proc_b",
        "_proc_c",
        "_proc_b_preempt",
        "_proc_c_preempt",
        "_tty_a",
        "_preemption_frame_state",
        "_preemption_rx_count",
    ):
        result[name] = transport.debug(b"\x03" + u24(symbols[name]) + b"\x1e")
    result["interrupt_enable"] = transport.debug(b"\x03" + u24(0xFF0010) + b"\x01")
    transport.debug(b"\x05")
    return {key: value.hex() if value is not None else None for key, value in result.items()}


def heartbeat(transport: Transport, tick: int):
    # Kind FE is a test-adapter command that injects its payload without SWT
    # framing, matching the hardware frontend's out-of-band UART heartbeat.
    transport.send(
        0xFE, bytes((0xFF, 1, tick & 255, tick >> 8 & 255, tick >> 16 & 255))
    )
    time.sleep(0.015)


def resource_sample(transport: Transport, tick: int, endpoints=(2,)):
    transport.send(8)
    latest = {}
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
        if payload[0] == 6 and len(payload) == 9 and payload[2] in endpoints:
            latest[payload[2]] = (
                int.from_bytes(payload[3:6], "little"),
                int.from_bytes(payload[6:9], "little"),
            )
        if payload[0] == 5 and all(endpoint in latest for endpoint in endpoints):
            return tick, latest
    raise AssertionError(
        "resource snapshot did not expose cpu-hog preemption; "
        f"last frames={observed[-20:]}"
    )


def saved_hog_r0(transport: Transport, tick: int, endpoint: int):
    transport.send(9, bytes((2, endpoint)))
    first = None
    second = None
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and (first is None or second is None):
        heartbeat(transport, tick)
        tick += 1
        received = transport.receive(0.05)
        if received is None or received[0] != 10:
            continue
        payload = received[2]
        if len(payload) == 15 and payload[:3] == bytes((2, endpoint, 0)):
            first = payload
        elif len(payload) == 9 and payload[:3] == bytes((2, endpoint, 1)):
            second = payload
    assert first is not None and second is not None, "no coherent saved cpu-hog context"
    return tick, int.from_bytes(first[3:6], "little")


def hog_endpoints(transport: Transport, tick: int, count: int = 2):
    """Endpoints the interrupt handler is forcibly preempting.

    The slots the hogs land in depend on what else booted, so they are found
    by what only a hog does -- accumulating forced preemptions -- rather than
    by assuming which numbers they were handed.
    """
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        transport.send(8)
        forced = {}
        generation = time.monotonic() + 5
        while time.monotonic() < generation:
            heartbeat(transport, tick)
            tick += 1
            # Drain everything between heartbeats. Reading one frame per
            # heartbeat falls behind a full process table, the pseudo-terminal
            # fills, and the next heartbeat blocks inside write() forever.
            ended = False
            while True:
                received = transport.receive(0.02)
                if received is None:
                    break
                if received[0] != 8:
                    continue
                payload = received[2]
                if payload[0] == 6 and len(payload) == 9:
                    if int.from_bytes(payload[3:6], "little"):
                        forced[payload[2]] = True
                elif payload[0] == 5:
                    ended = True
            if ended:
                break
        if len(forced) >= count:
            return tick, sorted(forced)[:count]
    raise AssertionError(f"only {sorted(forced)} were being preempted")


def kill_hog(transport: Transport, tick: int, endpoint: int):
    request = bytes((0x0D, endpoint))
    transport.send(9, request)
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        heartbeat(transport, tick)
        tick += 1
        received = transport.receive(0.05)
        if received is not None and received[0] == 10 and received[2][:2] == request:
            assert received[2] == request + b"\x00", received[2]
            return tick
    raise AssertionError("debugger could not kill saved cpu-hog context")


def assert_hog_absent(transport: Transport, tick: int, killed: int, survivor: int):
    transport.send(8)
    generation_started = False
    seen_killed = False
    seen_survivor = False
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        heartbeat(transport, tick)
        tick += 1
        received = transport.receive(0.05)
        if received is None or received[0] != 8:
            continue
        payload = received[2]
        if payload[:1] == b"\x01":
            generation_started = True
            seen_killed = False
            seen_survivor = False
        if generation_started and len(payload) >= 3 and payload[0] in (3, 4, 6):
            seen_killed |= payload[2] == killed
            seen_survivor |= payload[2] == survivor
        if generation_started and payload[:1] == b"\x05":
            if not seen_killed:
                assert seen_survivor, f"surviving cpu-hog disappeared with endpoint {killed}"
                return tick
            generation_started = False
            transport.send(8)
    raise AssertionError("no complete Resources generation after killing cpu-hog")


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
        # Queue two launches before the first hostile process can run. The
        # scheduler must subsequently keep Shell and framed control traffic
        # responsive while both children remain entirely non-cooperative.
        for command in (
            b"run cpu-hog --tty=new\r",
            b"run cpu-hog --tty=new\r",
        ):
            for byte in command:
                transport.send(1, bytes((byte,)), 0)
                time.sleep(0.003)

        tick = 1
        for _ in range(40):
            heartbeat(transport, tick)
            tick += 1
        try:
            tick, hogs = hog_endpoints(transport, tick)
            tick, first = resource_sample(transport, tick, tuple(hogs))
        except AssertionError as error:
            raise AssertionError(f"{error}; debug={diagnostic_state(transport)}") from error
        for _ in range(7):
            heartbeat(transport, tick)
            tick += 1
        tick, second = resource_sample(transport, tick, tuple(hogs))

        for endpoint in hogs:
            assert first[endpoint][0] > 0, first
            assert second[endpoint][0] > first[endpoint][0], (first, second)
            assert second[endpoint][1] != first[endpoint][1], (first, second)

        # Endpoint-aware debugger reads come from the quiescent ISR stack, not
        # from the emulator's globally running CPU. Two snapshots must prove
        # that the same saved r0 resumes and advances between preemptions.
        tick, debug_r0_first = saved_hog_r0(transport, tick, hogs[0])
        for _ in range(7):
            heartbeat(transport, tick)
            tick += 1
        tick, debug_r0_second = saved_hog_r0(transport, tick, hogs[0])
        assert debug_r0_second != debug_r0_first, (debug_r0_first, debug_r0_second)

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
        tick = kill_hog(transport, tick, hogs[0])
        tick = assert_hog_absent(transport, tick, hogs[0], hogs[1])
        print(
            "PASS: cpu-hog advanced under forced preemption "
            f"(ep{hogs[0]} forced {first[hogs[0]][0]}->{second[hogs[0]][0]}, "
            f"ep{hogs[1]} forced {first[hogs[1]][0]}->{second[hogs[1]][0]}, "
            f"debug r0 {debug_r0_first}->{debug_r0_second}) and was killed safely"
        )
    finally:
        os.close(slave)
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=2)


if __name__ == "__main__":
    main()
