#!/usr/bin/env python3
"""The file listing is an app in a pane, not a shell command.

`sdls` prints once where it was typed. That is fine for a script and wrong for
looking at a card: the listing scrolls away with everything else, and there is
nothing to refresh. `files` runs as an ordinary process, so the frontend gives
it a pane, `ps` lists it, and `kill` ends it like anything else.

It reads the built-in sample volume by default. The emulator cannot attach an
SD card and a terminal at the same time (docs/emulator-feature-requests.md),
and a pane that says "no valid SD card detected" and nothing else is not a file
manager. Pressing c asks for the card, which is what hardware has.
"""

import os
import pathlib
import pty
import subprocess
import sys
import tty
import importlib.util

ROOT = pathlib.Path(__file__).resolve().parent.parent
# The transport, framing and pumping are the debugger test's; this drives the
# same adapter over the same protocol and only asks different questions.
_spec = importlib.util.spec_from_file_location(
    "swtos_transport", ROOT / "tests" / "test-debugger-kill-acceptance.py"
)
_harness = importlib.util.module_from_spec(_spec)
sys.modules["swtos_transport"] = _harness
exec(
    compile(
        (ROOT / "tests" / "test-debugger-kill-acceptance.py").read_text().split("def main()")[0],
        "swtos_transport",
        "exec",
    ),
    _harness.__dict__,
)


def pane(output, channel):
    text = bytes(output.get(channel, b"")).decode("ascii", "replace")
    return [line for line in text.splitlines() if line.strip()]


def main() -> int:
    for artifact in (_harness.IMAGE, _harness.MAP, _harness.ADAPTER):
        assert artifact.exists(), f"missing {artifact}; run the documented build recipes"

    master, slave = pty.openpty()
    tty.setraw(slave)
    os.set_blocking(master, False)
    proc = subprocess.Popen(
        [str(_harness.ADAPTER), str(_harness.IMAGE), str(_harness.MAP), f"fd:{master}"],
        pass_fds=(master,), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    os.close(master)
    transport = _harness.Transport(slave)
    output: dict[int, bytearray] = {}
    try:
        transport.send(12, b"SWT1")
        assert transport.receive() == (13, 0, b"SWT1"), "adapter did not greet"
        tick = _harness.pump(transport, 1, 200, output)

        tick = _harness.type_slowly(transport, b"bg files\r", tick, output)
        tick = _harness.pump(transport, tick, 250, output)

        # A process, so it has an endpoint and a channel of its own. Which one
        # is not fixed: the monitor starts itself first, so this is whatever
        # slot was free, and the test must ask rather than assume.
        tick, states = _harness.slot_states(transport, tick)
        live = sorted(endpoint for endpoint, state in states.items() if state)
        assert len(live) >= 3, f"files did not start: {states}"
        endpoint = live[-1]
        channel = endpoint - 1

        shown = pane(output, channel)
        for expected in ("APPS <dir>", "HELLO.TXT 22"):
            assert any(expected in line for line in shown), \
                f"no '{expected}' in the pane: {shown}"
        assert any("Esc quit" in line for line in shown), \
            f"the pane did not say how to leave it: {shown}"

        # c asks for the card. There is none, and it says so rather than
        # showing the sample and pretending.
        output.clear()
        transport.send(1, b"c", channel)
        tick = _harness.pump(transport, tick, 250, output)
        assert any("no valid SD card detected" in line for line in pane(output, channel)), \
            f"c did not switch to the card: {pane(output, channel)}"

        # s goes back, and the listing is the one it started with.
        output.clear()
        transport.send(1, b"s", channel)
        tick = _harness.pump(transport, tick, 250, output)
        assert any("APPS <dir>" in line for line in pane(output, channel)), \
            f"s did not return to the sample: {pane(output, channel)}"

        # Escape ends it, the way every other resident app ends.
        transport.send(1, bytes([27]), channel)
        tick = _harness.pump(transport, tick, 250, output)
        tick, states = _harness.slot_states(transport, tick)
        assert not states.get(endpoint), \
            f"Escape left endpoint {endpoint} running: {states}"

        print(f"PASS: files ran as a pane app on endpoint {endpoint}, "
              f"switched sources, and left on Escape")
    finally:
        os.close(slave)
        if proc.poll() is None:
            proc.terminate()
            proc.wait()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
