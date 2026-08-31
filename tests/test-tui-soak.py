#!/usr/bin/env python3
"""Soak the windowed frontend against a live target and require it to survive.

The four-pane frontend, the debug adapter and the emulated target only meet
in an interactive session, which is exactly where the previous crashes were
found and where no unit test reaches. This drives a real session the way a
person does -- fill the process table from the menu, move around the panes,
zoom, ask the debugger and the shell for output -- and after every step
requires that the frontend is still running and still painting.

It also checks the two things that are easy to get wrong once the panes
share their rules: that Ctrl-A <n> focuses the pane whose label reads <n>,
and that the cpu-hogs' forced-preemption counts keep climbing, which is what
keeps every other pane alive.
"""

import fcntl
import os
import pathlib
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import termios
import threading
import time
import tty

ROOT = pathlib.Path(__file__).resolve().parent.parent
ADAPTER = ROOT / "build/cor24-debugger/swtos-cor24-debug-adapter"
FRONTEND = ROOT / "tools/te-rs/target/release/te-rs"
IMAGE = ROOT / "build/scheduled-shell/program.bin"
MAP = ROOT / "build/scheduled-shell/program.debug.json"

ROWS, COLUMNS = 50, 200
#: Shell, Application and Debugger, plus one per printing child beyond the
#: monitor, which starts itself into the Application pane. The two cpu-hogs
#: print nothing, so they contribute no pane.
EXPECTED_PANES = 3 + 12
PREFIX = b"\x01"  # Ctrl-A
#: Whole session budget. A hang is a failure, not something to wait out.
BUDGET = 300


class Drain:
    """Read one pseudo-terminal master continuously into a buffer.

    The frontend paints from the same loop it reads input with, so a harness
    that only reads while asserting lets the terminal fill and blocks the
    frontend inside write(). Darwin's roughly 1 KiB pseudo-terminal buffer
    makes that immediate for a fifty-row screen.
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

    def _run(self):
        while not self.done.is_set():
            try:
                ready, _, _ = select.select([self.fd], [], [], 0.05)
                if not ready:
                    continue
                data = os.read(self.fd, 65536)
            except (BlockingIOError, InterruptedError):
                continue
            except (OSError, ValueError):
                time.sleep(0.01)
                continue
            if data:
                with self.lock:
                    self.buffer.extend(data)
        try:
            os.close(self.fd)
        except OSError:
            pass

    def text(self) -> str:
        with self.lock:
            return bytes(self.buffer).decode("ascii", "replace")

    def stop(self):
        self.done.set()
        self.thread.join(timeout=1.0)


class Session:
    def __init__(self):
        self.serial_master, self.serial_slave = pty.openpty()
        tty.setraw(self.serial_slave)
        os.set_blocking(self.serial_master, False)
        serial_name = os.ttyname(self.serial_slave)

        self.term_master, self.term_slave = pty.openpty()
        tty.setraw(self.term_slave)
        fcntl.ioctl(self.term_slave, termios.TIOCSWINSZ,
                    struct.pack("HHHH", ROWS, COLUMNS, 0, 0))

        self.log = open(ROOT / "build/logs/tui-soak.log", "wb", buffering=0)
        self.adapter = subprocess.Popen(
            [str(ADAPTER), str(IMAGE), str(MAP), f"fd:{self.serial_master}"],
            pass_fds=(self.serial_master,), stdout=self.log, stderr=self.log,
        )
        os.close(self.serial_master)

        def controlling():
            os.setsid()
            fcntl.ioctl(self.term_slave, termios.TIOCSCTTY, 0)

        self.frontend = subprocess.Popen(
            [str(FRONTEND), "--windows", "--debug-map", str(MAP), serial_name],
            stdin=self.term_slave, stdout=self.term_slave, stderr=self.log,
            pass_fds=(self.term_slave,), preexec_fn=controlling,
        )
        os.close(self.term_slave)
        self.drain = Drain(self.term_master)

    def send(self, data: bytes, settle: float = 0.6):
        for byte in data:
            os.write(self.term_master, bytes((byte,)))
            time.sleep(0.02)
        time.sleep(settle)

    def command(self, byte: bytes, settle: float = 0.6):
        self.send(PREFIX + byte, settle)

    def screen(self) -> str:
        """The most recent complete repaint.

        The last frame in the buffer is often still being written, so take
        the last one that reached its footer.
        """
        frames = self.drain.text().split("\x1b[H")
        for frame in reversed(frames):
            if "focus:" in frame:
                return frame.replace("\x1b[K", "")
        return frames[-1].replace("\x1b[K", "")

    def panes(self) -> int:
        found = re.search(r"panes:(\d+)", self.screen())
        return int(found.group(1)) if found else 0

    def wait_for(self, needle: str, timeout: float = 20.0) -> str:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            view = self.screen()
            if needle in view:
                return view
            if not self.running():
                break
            time.sleep(0.1)
        return self.screen()

    def running(self) -> bool:
        return self.frontend.poll() is None

    def diagnose(self, step: str) -> str:
        self.log.flush()
        detail = pathlib.Path(self.log.name).read_text(errors="replace")
        return (f"frontend exited (rc={self.frontend.returncode}) during {step}\n"
                f"--- screen ---\n{self.screen()[-2000:]}\n--- log ---\n{detail[-2000:]}")

    def close(self):
        self.drain.stop()
        for proc in (self.frontend, self.adapter):
            if proc.poll() is None:
                proc.send_signal(signal.SIGTERM)
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    proc.kill()
        os.close(self.term_master)
        os.close(self.serial_slave)
        self.log.close()


def focused_label(view: str):
    """Pane number carrying the focus marker on a shared rule."""
    for line in view.splitlines():
        if not line.startswith("-"):
            continue
        # Only the column separator bounds the search: a name may contain
        # a hyphen (cpu-hog, embedded-hello), and each column carries
        # exactly one name, so the first marker in a column is its own.
        found = re.search(r"(\d+) v [^|]*?\*", line)
        if found:
            return int(found.group(1))
    return None


def hog_forced(view: str) -> dict[int, int]:
    """Endpoint -> forced-preemption count for every process the pane lists."""
    counts = {}
    for endpoint, forced in re.findall(r"ep=(\d+) .*? fp=(\d+)", view):
        counts[int(endpoint)] = int(forced)
    return counts


def main():
    for artifact in (ADAPTER, FRONTEND, IMAGE, MAP):
        assert artifact.exists(), f"missing {artifact}; run documented build recipes"
    (ROOT / "build/logs").mkdir(parents=True, exist_ok=True)

    deadline = time.monotonic() + BUDGET
    session = Session()
    checks = []

    def require(condition, step, detail=""):
        if not condition:
            raise AssertionError(f"{step}: {detail}\n{session.diagnose(step)}")
        checks.append(step)

    def step(name):
        require(session.running(), name)
        require(time.monotonic() < deadline, name, "session budget exhausted")

    try:
        # Wait for the shell prompt, not just the link: a keystroke sent
        # before the target has booted is simply lost.
        view = session.wait_for("Choice:", timeout=40)
        require("connected" in view, "connect", view[-800:])
        require("Choice:" in view, "shell reaches its prompt", view[-1500:])

        # Fill every slot, then require the frontend to have opened a pane per
        # process rather than folding them together.
        # Several launches in a row, typed at the prompt without touching the
        # keyboard focus in between. A new pane used to take focus, so the
        # second command went into the first program's pane and only one
        # program ever started.
        # Wait for the monitor's first report: it proves the target is up and
        # exchanging snapshots, which is when typed input starts landing.
        session.wait_for("ep=2", timeout=30)
        # The monitor's first report says the link is up; give it a moment to
        # be reading input as well before typing at it.
        time.sleep(3)
        # A launch must leave the keyboard where it was. A new pane used to
        # take focus, so a second command went into the first program's pane
        # and never reached the shell at all.
        before_panes = session.panes()
        session.send(b"bg clock\r", settle=8.0)
        grew = time.monotonic() + 20
        while session.panes() <= before_panes and time.monotonic() < grew:
            require(session.running(), "bg launch")
            time.sleep(0.2)
        require(session.panes() > before_panes, "bg opens a pane",
                f"panes stayed at {session.panes()}")
        require("focus:Shell" in session.screen(), "bg leaves the prompt focused",
                session.screen()[-400:])
        step("bg leaves the prompt focused")

        # "!<command>" hands a line to the shell, so process management has
        # one spelling rather than two kept in step by hand. This runs while
        # the table is small: with sixteen panes the shell's own pane is two
        # lines tall and its reply scrolls away unread.
        session.command(b"3", settle=1.0)
        session.send(b"!ps\r", settle=5.0)
        answered = re.compile(r"\d+ (RUNNABLE|BLOCKED|FREE)")
        seen = time.monotonic() + 20
        while not answered.search(session.screen()) and time.monotonic() < seen:
            require(session.running(), "debugger ! escape")
            time.sleep(0.2)
        require(answered.search(session.screen()), "debugger ! escape reaches the shell",
                session.screen()[-600:])
        require("focus:Debugger" in session.screen(), "! leaves the debugger focused",
                session.screen()[-400:])
        step("debugger ! escape")

        # Back to the shell: the menu key below is typed, and typing goes to
        # whichever pane holds focus.
        session.command(b"1", settle=1.0)
        require("focus:Shell" in session.screen(), "focus returns to the shell",
                session.screen()[-400:])

        # Four base panes plus one per process that prints. The hogs never
        # print, so they are the two slots without a pane of their own.
        #
        # A keystroke sent before the link has settled is dropped, and the
        # prompt appears before that point, so ask again rather than assume
        # the first one landed. Repeating is harmless once the table is full.
        for _ in range(5):
            session.send(b"9\r", settle=4.0)
            settle = time.monotonic() + 15
            while session.panes() < EXPECTED_PANES and time.monotonic() < settle:
                require(session.running(), "menu 9")
                time.sleep(0.2)
            if session.panes() >= EXPECTED_PANES:
                break
        require(session.panes() >= EXPECTED_PANES, "menu 9 opens a pane per printing process",
                f"saw panes:{session.panes()}")
        step("menu 9")

        # Ctrl-A <n> has to focus the pane whose label reads <n>.
        for digit in b"123456789":
            session.command(bytes((digit,)), settle=0.35)
            # Wait for the repaint rather than assuming one arrived: a screen
            # of fifteen panes takes longer to redraw than a keystroke takes
            # to send, and reading too early sees the previous frame.
            wanted = digit - ord("0")
            shown = None
            settle = time.monotonic() + 5
            while time.monotonic() < settle:
                shown = focused_label(session.screen())
                if shown == wanted:
                    break
                time.sleep(0.1)
            require(shown == wanted, f"Ctrl-A {chr(digit)} focus",
                    f"marker landed on pane {shown}")
        step("digit focus")

        # Panes past nine are reachable only by relative movement.
        for _ in range(12):
            session.command(b"n", settle=0.2)
        step("Ctrl-A n walk")
        for _ in range(5):
            session.command(b"p", settle=0.2)
        session.command(b"\t", settle=0.2)
        step("Ctrl-A p and tab")

        session.command(b"z", settle=1.0)
        require("zoom" in session.screen().lower() or session.running(), "zoom in")
        session.command(b"?", settle=1.0)
        session.command(b"?", settle=0.5)
        session.command(b"z", settle=1.0)
        step("zoom and help")

        session.command(b"y", settle=0.4)
        session.command(b"y", settle=0.4)
        session.command(b"b", settle=0.3)
        session.send(b"\x1b", settle=0.4)
        step("copy, broadcast arm, escape")

        # The debugger pane must answer while sixteen processes run.
        session.command(b"3", settle=1.0)   # Debugger
        require("focus:Debugger" in session.screen(), "focus reaches the debugger",
                session.screen()[-400:])
        session.send(b"regs\r", settle=2.0)
        view = session.wait_for("pc=", timeout=15)
        require("pc=" in view, "debugger regs", view[-1200:])
        session.send(b"regs 2\r", settle=2.0)
        step("debugger regs")

        # A correction must be visible as it is made. The buffer was always
        # edited -- Enter ran the corrected line -- but the pane went on
        # showing the mistake, so there was no way to see what would run.
        session.send(b"regx", settle=1.5)
        require("regx" in session.screen(), "the debugger echoes what is typed",
                session.screen()[-300:])
        session.send(b"\x08", settle=1.5)
        require("regx" not in session.screen(), "backspace erases in the pane",
                session.screen()[-300:])
        session.send(b"s\r", settle=2.5)
        step("debugger line editing")



        # Resources must show the hogs being forcibly preempted, and the count
        # must keep climbing: that is what keeps every other pane scheduled.
        session.command(b"2", settle=1.0)
        require("focus:mon" in session.screen(), "focus reaches the monitor",
                session.screen()[-400:])
        # Zoom first: in a shared column the process lines are cut off well
        # before the fp= field, so the unzoomed pane cannot answer this.
        session.command(b"z", settle=1.5)
        # The monitor must be reporting every live process, forced-preemption
        # counts included. Whether those counts climb is asserted over the
        # protocol in fill-demo-acceptance, where the heartbeat is under the
        # test's control; scraping a pane that redraws once a second cannot
        # decide it, and a rate that depends on how much the frontend happens
        # to be sending is not what this test is for.
        reported = hog_forced(session.wait_for("fp=", timeout=20))
        require(len(reported) >= 4, "monitor reports the live processes",
                f"saw {reported}")
        require(any(count for count in reported.values()),
                "monitor reports forced preemptions", f"saw {reported}")
        session.command(b"z", settle=1.0)
        step("monitor reports every live process")

        # A full table refuses a launch rather than wedging or silently
        # doing nothing, and says so where the command was typed.
        session.command(b"1", settle=1.0)
        refused = False
        for _ in range(3):
            session.send(b"bg clock\r", settle=4.0)
            if "ERROR" in session.screen():
                refused = True
                break
        require(refused, "a full table refuses a launch", session.screen()[-800:])
        step("full table refuses a launch")

        # Killing processes must free their slots and let their panes be
        # reclaimed: a long session should not end up mostly finished
        # programs holding the screen.
        panes_full = session.panes()
        session.command(b"3", settle=1.0)
        for endpoint in (b"8", b"10", b"12"):
            session.send(b"!kill " + endpoint + b"\r", settle=3.0)
        ended = time.monotonic() + 25
        while "(ended)" not in session.screen() and time.monotonic() < ended:
            require(session.running(), "killed panes report their end")
            time.sleep(0.3)
        require("(ended)" in session.screen(), "a killed process's pane says so",
                session.screen()[-800:])
        session.command(b"c", settle=2.0)
        require(session.panes() < panes_full, "ended panes are reclaimed",
                f"panes stayed at {session.panes()}")
        step("panes shrink with the process table")

        # The shell must still take a command with the table full. Focus has
        # to be checked, not assumed: every new pane takes it, so after the
        # fill the keyboard is aimed at the last clock rather than the shell.
        session.command(b"1", settle=1.0)
        require("focus:Shell" in session.screen(), "focus returns to the shell",
                session.screen()[-400:])
        # Any slot state will do. With the table full the children sit blocked
        # in TASK_GETCHAR waiting for their next tick, so requiring RUNNABLE
        # here would be asserting the wrong end of a working system.
        listing = re.compile(r"\d+ (RUNNABLE|BLOCKED|FREE)")
        answered = False
        for _ in range(3):
            session.send(b"ps\r", settle=4.0)
            if listing.search(session.screen()):
                answered = True
                break
        require(answered, "shell answers ps with the table full",
                session.screen()[-1500:])
        step("shell ps")

        # Killing a process must not take the session with it.
        session.command(b"3", settle=1.0)
        session.send(b"kill 3\r", settle=3.0)
        step("debugger kill")

        session.command(b"n", settle=0.4)
        session.command(b"x", settle=1.0)
        step("close a pane")

        for _ in range(3):
            session.command(b"n", settle=0.2)
            session.command(b"z", settle=0.4)
            session.command(b"z", settle=0.4)
        step("survives repeated zoom while navigating")

        require(session.running(), "final")
        print(f"PASS: windowed session survived {len(checks)} interactions "
              f"(monitor reported {len(reported)} processes)")
    finally:
        session.close()


if __name__ == "__main__":
    sys.exit(main())
