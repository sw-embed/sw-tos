# SWTOS Windows Frontend

The SWTOS Windows frontend is a tiled terminal interface for the framed SWTOS
transport. It keeps Shell, application, debugger, and resource-monitor output
in independent panes while the COR24 target continues to own scheduling,
virtual TTYs, process state, and memory accounting.

## Emulator demo

Build the scheduled image, pinned COR24 debugger adapter, and Rust frontend,
then open the four-pane desktop with:

```sh
just cor24-debugger-demo
```

The recipe uses `build/sessions/demo.json` to save and restore its layout. To
start without a saved layout, pass another session path:

```sh
just cor24-debugger-demo session=build/sessions/fresh.json
```

## COR24-TB hardware

Build the frontend and attach it to the already-running resident image:

```sh
just te-rs-release
tools/te-rs/target/release/te-rs \
  --windows \
  --debug-map build/scheduled-shell/program.debug.json \
  --session build/sessions/hardware.json \
  DEVICE
```

Use the stable `/dev/serial/by-id/` path for `DEVICE`. `--windows` implies the
negotiated framed SWTOS transport. Only one frontend may own the UART at a
time. Hardware upload and validation remain governed by
[`hw-validation.md`](hw-validation.md).

## Panes and input

The initial panes are Shell, Application, Debugger, and Resources. The focused
pane has `*` in its title and exclusively receives ordinary input. SWTOS does
not echo framed input, so the frontend locally displays printable input,
backspace, and Enter in Shell and Application panes.

The default host prefix is Ctrl-A. Release Ctrl-A before typing its command;
each focus change needs its own prefix. For example, `Ctrl-A 2`, `Ctrl-A 3`
focuses Application and then Debugger, while `Ctrl-A 2 3` focuses Application
and sends the unprefixed `3` to it.

| Prefix command | Action |
|---|---|
| `1` through `9` | Focus a pane by number |
| `n` | Focus the next pane |
| `s` | Add a pane |
| `a` | Assign the focused pane to an unused channel |
| `x` | Close the focused pane |
| `z` | Toggle zoom for the focused pane |
| `y` | Enter or leave copy mode |
| `e` | Send Escape to the focused Shell or Application pane |
| `r` | Resynchronize heartbeat framing, renegotiate, refresh Resources, and redraw |
| `R` | Restore the saved pane layout from `--session` |
| `w` | Save the layout passed with `--session` |
| `b`, then prefix-`b` again | Toggle guarded broadcast input |
| `?` | Toggle help |
| `d` | Detach and restore the host terminal |

Ctrl-C also exits and restores the terminal, including from copy mode. Prefer
prefix-`d` when demonstrating a deliberate detach. Prefix-Escape cancels a
pending broadcast and leaves copy mode without sending Escape to SWTOS; use
prefix-`e` when an application such as Uptime must receive Escape.

## Copy mode and scrollback

Focus a pane and press Ctrl-A then `y`. `COPY` appears in the status line and
navigation remains local to the frontend:

| Key | Action |
|---|---|
| Up / `k` | One line toward older output |
| Down / `j` | One line toward live output |
| Left / `h` | Scroll left |
| Right / `l` | Scroll right |
| Page Up / `u` | Ten lines toward older output |
| Page Down / `d` | Ten lines toward live output |
| `g` | Oldest retained output and left edge |
| `G` | Live output and left edge |
| `q` | Leave copy mode |

Each pane retains up to 1,000 completed lines independently.

## Shell and applications

The Shell accepts numeric menu choices and commands such as:

```text
help
ls
ps
ps -l
run counter
run counter --tty=new
```

`run NAME --tty=new` asks the frontend for another application pane. Uptime
and Clock receive host time frames only while the Resources snapshot reports
the matching live process. Stop either application by focusing its pane and
pressing Ctrl-A then `e`.

For the two-context hostile-load demonstration, keep Shell interactive with:

```text
run cpu-hog --tty=new
run cpu-hog --tty=new
ps -l
```

The first command claims application channel 1/endpoint 2 and the second claims
channel 2/endpoint 3 without stealing Shell focus. Both run the exact assembly
listed in `preemptive-multitasking.md`. Use `regs 2` and `regs 3`; `kill 2`
terminates only the first, after which Resources and `ps -l` must still show
endpoint 3 advancing.

The tracked preemption tape first uses those application panes for `uptime`
and `clock`, stops both with Ctrl-A then `e`, and then reuses the freed
endpoints and panes for the two hogs. This contrasts normal blocking
applications with forced
preemption while keeping the final two-hog acceptance evidence unambiguous.

The Application pane retains completed output as scrollback. Text such as
`Uptime` remaining there does not mean the process is still running; Resources
is authoritative. A live time application appears as `upti` or `cloc` and
increments the used-slot count.

## Resources

Resources is read-only and refreshes four times per second. It reports memory
use and peak, kernel-stack peak, allocation failures, process slots and state,
scheduler activity, IPC and TTY counts, UART traffic, and protocol errors.
Zoom or use copy mode to inspect values wider than a tiled pane.

Each process row also shows `fp=` (forced preemptions) and `cpu=` (the most
recent interrupted `r0` sample). A non-yielding `cpu-hog` should show both
values changing while Shell, Debugger, and Resources remain responsive. The
sample is a deliberately simple acceptance-test indicator, not general CPU
usage accounting.

For a runway-saved process, `regs EP` returns its coherent interrupted frame
and saved PC; requesting registers does not itself preempt the process. Run it
twice with heartbeats between requests to verify that the saved `r0` counter
changes across resume/preemption cycles. `kill EP` queues safe termination of
a certified hostile process. SWTOS reclaims only a complete parked context via
the ordinary task-exit path, after which Resources omits the endpoint.

`STALE` means no complete snapshot arrived for one second. `resource data
unavailable` means the frontend has not yet received a complete generation.

The frontend sends scheduler heartbeats while framed-mode negotiation is still
in progress and retries `HELLO` periodically. This is required when reconnecting
after a crash or detach that left a non-yielding process current: the target
needs clock interrupts before its transport task can run and acknowledge the
new frontend. Prefix-`r` restarts clock-assisted negotiation when disconnected;
when already connected it preserves the live decoder and immediately requests
a fresh Resources generation. A malformed frame is reported in the footer,
but a subsequent valid frame clears that transient transport diagnostic.

## Debugger

The Debugger pane accepts host-side commands rather than SWTOS TTY input:

```text
help
sym NAME
list NAME|ADDRESS
dis NAME|ADDRESS [COUNT]
regs [ENDPOINT]
x ADDRESS [1..12]
kill ENDPOINT
```

Symbolic commands require the target build ID to match the selected debug map.
Registers and memory are read-only hardware-safe operations. `kill` is limited
to a certified hostile process parked at a safe interrupt context. Breakpoints,
continue, step, next, and backtrace use the emulator-backed debugger; arbitrary
instruction breakpoints are not supported on the physical COR24-TB.

## Reproducible recording

The tracked VHS tape demonstrates pane focus, Shell commands, Resources,
symbolic debugging, zoom, and scrollback against the emulator:

```sh
just windows-demo-record
```

Recording requires `vhs`, Cargo, and FFmpeg. `just windows-demo-tools` resolves
and prints the exact tools first. The tracked wrapper adds the conventional
Go, Cargo, and user-local binary directories (`$GOPATH/bin`,
`$CARGO_HOME/bin`, and `$HOME/.local/bin`) to the inherited system `PATH`, so
the recording does not depend on login-shell initialization. The tape is
validated before the image and pinned emulator adapter are built.

The recipe writes the master recording under ignored `build/captures/` and
encodes the checked-in VP9 README asset at `videos/cor24-windows-demo.webm`.
Use `just windows-demo-inspect` to extract representative ignored PNG frames
from the master for review.
