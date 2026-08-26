#!/usr/bin/env python3
"""End-to-end emulator debugger proof over the SWTOS framed PTY transport."""

import json
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
            ready, _, _ = select.select([self.fd], [], [], max(0, deadline - time.monotonic()))
            if ready:
                self.pending += os.read(self.fd, 4096)
        raise AssertionError("timed out waiting for emulator frame")

    def debug(self, payload: bytes):
        self.send(9, payload)
        while True:
            kind, _, response = self.receive()
            if kind == 10:
                return response

    def registers(self):
        self.send(9, b"\x02\x01")
        parts = {}
        while len(parts) != 2:
            kind, _, response = self.receive()
            if kind == 10 and response[:2] == b"\x02\x01":
                parts[response[2]] = response
        return parts


def u24(value: int) -> bytes:
    return bytes((value & 255, value >> 8 & 255, value >> 16 & 255))


def main():
    for artifact in (IMAGE, MAP, ADAPTER):
        assert artifact.exists(), f"missing {artifact}; run documented build recipes"
    debug_map = json.loads(MAP.read_text())
    counter = next(item["address"] for item in debug_map["symbols"] if item["name"] == "_PLSW_COUNTER")
    loop = next(item["address"] for item in debug_map["instructions"] if item["address"] > counter and " ".join(item["text"].split()) == "lw r0,-3(fp)")

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
        try:
            hello = transport.receive()
        except AssertionError:
            if proc.poll() is not None:
                raise AssertionError(proc.stderr.read().decode())
            raise
        assert hello == (13, 0, b"SWT1")
        listed = transport.debug(b"\x06" + u24(counter))
        assert listed == b"\x08\x01" + u24(counter)
        transport.debug(b"\x05")

        # Feed one byte at a time so the emulated one-byte UART RX register is
        # consumed between writes, exactly like paced hardware input.
        for byte in b"run counter\r":
            transport.send(1, bytes((byte,)), 0)
        while True:
            kind, _, payload = transport.receive(10)
            if kind == 10 and payload[:2] == b"\x04\x01":
                assert payload[2:5] == u24(counter)
                break

        regs = transport.registers()[0]
        assert regs[:3] == b"\x02\x01\x00" and len(regs) == 15
        # Enter the prologue and inspect Counter's private pointer local.
        for _ in range(7):
            transport.debug(b"\x09")
        state = transport.registers()[0]
        fp = int.from_bytes(state[9:12], "little")
        private = transport.debug(b"\x03" + u24((fp - 3) & 0xFFFFFF) + b"\x03")
        assert len(private) == 7 and int.from_bytes(private[4:], "little") != 0

        # Reach and execute the increment, proving r0 changes by one.
        for _ in range(7):
            transport.debug(b"\x09")
        pre_add = transport.registers()[0]
        transport.debug(b"\x09")
        post_add = transport.registers()[0]
        get_r0 = lambda data: int.from_bytes(data[3:6], "little")
        assert get_r0(post_add) == (get_r0(pre_add) + 1) & 0xFFFFFF
        assert transport.debug(b"\x08") == b"\x08\x01" + u24(counter)
        assert transport.debug(b"\x0b")[0] == 11

        # Move the user breakpoint to Counter's loop body. Continue reaches it
        # repeatedly; the breakpoint list remains free of temporary entries.
        assert transport.debug(b"\x07" + u24(counter)) == b"\x08\x00"
        assert transport.debug(b"\x06" + u24(loop)) == b"\x08\x01" + u24(loop)
        transport.debug(b"\x05")
        while True:
            kind, _, payload = transport.receive(10)
            if kind == 10 and payload[:2] == b"\x04\x01":
                assert payload[2:5] == u24(loop)
                break
        assert transport.debug(b"\x08") == b"\x08\x01" + u24(loop)
        transport.debug(b"\x0c")
        proc.wait(timeout=2)
        assert proc.returncode == 0

        # A stopped emulator process may disappear without leaving the PTY
        # harness or frontend cleanup path wedged.
        master2, slave2 = pty.openpty()
        tty.setraw(slave2)
        os.set_blocking(master2, False)
        exited = subprocess.Popen(
            [str(ADAPTER), str(IMAGE), str(MAP), f"fd:{master2}"],
            pass_fds=(master2,), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        os.close(master2)
        stopped = Transport(slave2)
        stopped.send(12, b"SWT1")
        assert stopped.receive() == (13, 0, b"SWT1")
        assert stopped.debug(b"\x04")[:2] == b"\x04\x02"
        exited.terminate()
        exited.wait(timeout=2)
        os.close(slave2)
        print("emulator debugger Counter session: PASS")
    finally:
        os.close(slave)
        if proc.poll() is None:
            proc.terminate()
            proc.wait()


if __name__ == "__main__":
    main()
