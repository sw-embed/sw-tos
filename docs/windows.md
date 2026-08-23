# SWTOS Window System and Interactive Debugger Plan

Copyright (c) 2026 Michael A Wright

## Purpose

This document plans an incremental SWTOS terminal environment inspired by
early tiled desktops and DOS split-screen executives. Multiple SWTOS programs
will run concurrently in virtual terminal windows. A host-side Rust frontend
will display a shell, debugger, application consoles, and resource monitor in
a tiled ANSI terminal interface.

Development is emulator-first. Hardware testing begins only after the protocol,
scheduler behavior, debugger, and terminal restoration have deterministic
emulator coverage.

## Architectural boundary

The COR24 target owns process scheduling, virtual terminals, input blocking,
resource accounting, and debug state. The host owns presentation, keyboard
shortcuts, scrollback, layout, and debug-symbol files.

```text
SWTOS processes
 shell  debugger  app A  app B  monitor
    \      |       |      |       /
       virtual TTY and kernel services
                  |
          framed byte transport
                  |
      Rust terminal or COR24 emulator
                  |
          tiled ANSI terminal UI
```

Applications must not write directly to the physical UART. Each application
writes to a virtual TTY channel and blocks in `TTY_READ` when its input buffer
is empty. A blocked reader yields the processor; it must not spin. The focused
host window receives keyboard input while output from every runnable process
continues to be collected.

The initial implementation keeps debug maps and window scrollback on the host.
This preserves target RAM and lets the frontend reject a symbol map whose build
ID does not match the loaded image.

## Compatibility and constraints

- Preserve the current plain terminal as a recovery and diagnostics mode.
- Carry clock traffic in the framed protocol so it never leaks into TTY output.
- Retain full-speed UART flow control and tolerate fragmented frames.
- Allow only one frontend to own a UART or emulator terminal at a time.
- Restore the user's terminal on Ctrl-C, detach, transport loss, and fatal error.
- Do not describe scheduler dispatch counts as CPU percentages. COR24 currently
  lacks an independent target timer suitable for accurate CPU accounting.
- Treat arbitrary hardware breakpoints as a feasibility-gated feature. Emulator
  debugging and cooperative hardware checkpoints remain useful independently.

## Proposed interfaces

The names below describe contracts, not final source-language syntax.

```text
TTY_WRITE(endpoint, bytes)
TTY_READ(endpoint, buffer, length)
TTY_STATUS(endpoint)
TTY_SET_MODE(endpoint, flags)

SYS_INFO()
PROC_INFO(endpoint)
MEM_INFO()

DEBUG_ATTACH(endpoint)
DEBUG_BREAK(location)
DEBUG_CONTINUE(endpoint)
DEBUG_STEP(endpoint)
```

The UART or emulator byte stream will use self-synchronizing frames:

```text
sync | protocol version | type | channel | length | payload | checksum
```

Initial message types should cover TTY input and output, channel lifecycle and
title changes, clock updates, resource snapshots, debugger requests and
responses, protocol errors, and resynchronization.

## Saga development model

All work belongs on the `feature/windows` branch until the complete saga is
ready to merge. Each numbered step below produces one feature commit. A commit
must leave the emulator acceptance suite passing and must include its tests and
documentation. Mechanical corrections discovered during a step are folded into
that step before moving on; later regressions receive a separate, clearly named
fix commit rather than rewriting already shared history.

The initial validation boundary is entirely emulated:

- No step requires the COR24-TB, UART adapter, or physical reset.
- Protocol tests inject fragmentation, corruption, and disconnects.
- Interactive behavior is exercised through PTYs or an equivalent deterministic
  frontend harness.
- Debugger tests use fixed programs and assert breakpoint, register, memory, and
  source-location results.
- Each step runs its focused smoke test plus `just emulator-acceptance`.

Hardware validation will be planned as a separate follow-on saga after the
emulator feature branch is stable.

## Saga 1 -- Memory accounting and `mem`

**Status:** Complete on the emulator feature branch.

Add linker-defined image bounds and allocator accounting for arena start,
current use, high-water mark, allocation failure, process stack/state sizes,
and process-slot use. Fill the kernel stack with a recognizable pattern so its
high-water mark can be measured safely.

Add these shell forms:

```text
mem       summary
mem -p    per-process allocation
mem -r    reset resettable high-water counters
```

The output must distinguish 24-bit words from packed host bytes. It must also
state which values are measured and which are fixed build-time values.

Acceptance: launching one and two counters changes current and peak allocation;
process exit restores reclaimable arena space; emulator tests cover allocator
failure and kernel-stack watermark reporting.

Commit: `feat(mem): add runtime memory accounting and mem command`

## Saga 2 -- Process activity statistics

Expose endpoint, catalog identity, process state, blocked reason, configured
stack/state allocation, scheduler dispatches, yields, IPC operations, and TTY
byte counts. Extend `ps` with a detailed form and add `stat <endpoint>`.

Activity initially means dispatches or heartbeat-relative deltas, not CPU time.
Counters should saturate or wrap in a documented manner appropriate for 24-bit
words.

Acceptance: scheduler, IPC, and counter demos produce deterministic counter and
state transitions.

Commit: `feat(stats): expose per-process resource and activity counters`

## Saga 3 -- Kernel virtual terminals

Introduce a fixed, small virtual-TTY table with per-channel input buffering,
serialized output, owner endpoint, foreground state, mode flags, dimensions,
and overflow counters. Route shell and applications through TTY services rather
than physical UART calls.

An empty `TTY_READ` moves the caller to `BLOCKED_TTY`. Input arrival wakes the
appropriate process. Initially support at least four channels and make buffer
limits explicit.

Acceptance: a shell and two interactive programs run concurrently, retain
separate streams, and cannot consume one another's input. A blocked reader
does not accumulate dispatches in a busy loop.

Commit: `feat(tty): add blocking virtual terminal channels`

## Saga 4 -- Multiplexed transport

Implement the versioned framed protocol in SWTOS, the emulator integration,
and a reusable Rust protocol library. Fold existing heartbeat and wall-clock
messages into typed frames.

The decoder must recover after garbage, bad checksums, truncated frames, and
unknown message types. Per-channel output must remain ordered, with explicit
overflow and backpressure behavior. A disconnect must not leave an unrecoverable
partial frame or permanently blocked target process.

Acceptance: property or table-driven tests cover round trips, every split point,
corruption, resynchronization, literal synchronization bytes, and reconnect.

Commit: `feat(protocol): multiplex tty clock resource and debug frames`

## Saga 5 -- Minimal tiled Rust frontend

Extend `te-rs` with a fixed four-pane desktop:

```text
+----------------------+----------------------+
| Shell                | Application          |
|                      |                      |
+----------------------+----------------------+
| Debugger             | Resources            |
|                      |                      |
+----------------------+----------------------+
| focus help connection clock and error state |
+---------------------------------------------+
```

Provide per-pane scrollback, focus indication, resize handling, and terminal
restoration. Only the focused channel receives ordinary keystrokes. A
configurable host-command prefix selects panes, cycles focus, zooms a pane,
shows help, and detaches. The prefix must coexist with the existing Ctrl-]
behavior during migration.

Acceptance: a PTY-driven test switches focus among shell and applications,
verifies independent input/output and scrollback, resizes the terminal, then
exits through both normal and failure paths with terminal modes restored.

Commit: `feat(windows): add four-pane Rust terminal frontend`

## Saga 6 -- Resource and activity monitor

Add a host-rendered resource pane fed by low-rate target snapshots plus process
spawn, exit, block, wake, and allocation events. Display process states,
dispatch activity, stack/state allocation, memory current/peak values, IPC
counters, UART traffic, and protocol errors.

Begin with a two-to-four-Hz refresh rate. Avoid continuous repaint traffic when
the values have not changed. Make stale or disconnected data visibly distinct
from a valid zero.

Acceptance: resource rows appear and disappear with processes, blocked states
are visible, memory is reclaimed after exit, and reconnect produces a fresh
complete snapshot.

Commit: `feat(monitor): add tiled process and memory resource monitor`

## Saga 7 -- Debug artifacts and symbolic inspection

Generate `program.debug.json` beside `program.bin`. It should contain a build
ID or image hash, symbols, instruction and function boundaries, source/line
mappings, and supported variable locations. The running target reports the
same build identity.

Add host debugger commands for symbol lookup, source listing, disassembly,
register display, memory examination, breakpoint listing, and breakpoint
deletion. Raw-address inspection may remain available after a map mismatch,
but symbolic operations must fail clearly.

Acceptance: deterministic tests resolve functions and source lines, reject a
mismatched map, and inspect known registers and memory without changing target
execution.

Commit: `feat(debug-info): add build-matched symbolic inspection`

## Saga 8 -- Emulator breakpoints and execution control

Implement pause, continue, address/function/source breakpoints, breakpoint
hit events, instruction step, step-over, register access, memory access, and a
best-effort ABI-aware backtrace in the emulator. Temporary breakpoints used by
step-over must not leak into the user's breakpoint list.

The debugger window uses the same logical debug protocol intended for future
hardware support, even if its emulator transport is initially a PTY, pipe, or
socket.

Acceptance: a scripted Counter session breaks at entry, lists the breakpoint,
inspects private state, steps across an increment, continues, and hits the
breakpoint again. Tests cover detach and process exit while stopped.

Commit: `feat(debugger): add emulator breakpoints step and continue`

## Saga 9 -- Dynamic windows and sessions

Generalize the fixed layout to create, close, split, assign, cycle, and zoom
panes. Add scrollback search, copy mode, saved layouts, background-input alerts,
and explicit opt-in broadcast input. Allow the shell to launch an application
into a new virtual terminal.

Possible commands include:

```text
run counter --tty=new
windows
focus 3
```

Acceptance: a saved session layout can be restored against a fresh emulator;
closed or exited processes do not leave dead channel ownership; broadcast input
cannot be enabled accidentally.

Commit: `feat(windows): add dynamic panes and session management`

## Deferred hardware saga

Hardware validation starts only after Sagas 1 through 9 pass emulator
acceptance. Its first step will verify framed UART transport, flow control,
disconnect recovery, TTY focus, and monitoring without enabling instruction
breakpoints.

The next step will add cooperative process debugging: attach to a process,
request a pause at its next kernel boundary, inspect its saved context, and
continue it. This remains useful even if arbitrary instruction interception is
not feasible.

True software breakpoints require a COR24 feasibility investigation covering:

1. A reliable trap or illegal instruction.
2. Preservation and modification of the interrupted PC.
3. Writable executable memory and any cache synchronization.
4. Safe restoration and reinsertion of the replaced instruction.
5. Successor decoding for branches, calls, returns, and indirect jumps.

If the interrupt ABI cannot provide these guarantees, instruction breakpoints
and single-step will remain emulator-only while hardware uses cooperative debug
checkpoints. This limitation must not block virtual terminals, the window
system, resource monitoring, or symbolic inspection.

## Completion criteria

The emulator saga is complete when:

- the shell, debugger, resource monitor, and at least two applications operate
  concurrently in isolated virtual terminals;
- keyboard focus exclusively routes input to the selected application;
- empty input blocks and yields rather than spins;
- `mem`, detailed process statistics, and monitor values agree;
- symbolic emulator breakpoints, listing, stepping, and continue work against a
  build-matched debug map;
- protocol corruption and disconnect are recoverable;
- the plain terminal remains available as a recovery path; and
- every saga commit passes its focused tests and `just emulator-acceptance`.
