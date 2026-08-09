# SWTOS -- Software Wrighter Tiny Operating System

*A portable microkernel for educational and embedded systems.*

## Overview

SWTOS is a clean-room microkernel operating system inspired by MINIX IPC
principles but designed natively for small CPUs and FPGA soft cores. It
runs on the [COR24-TB](https://www.makerlisp.com/cor24-test-board) FPGA
development board (MakerLisp COR24 soft CPU, 1 MB SRAM, 101.7 MHz) and in
a companion software emulator.

SWTOS is implemented in [PL/SW](https://github.com/sw-embed/sw-cor24-plsw),
a PL/I-inspired systems programming language for the COR24 ISA.

### Key Features

- **Synchronous message-passing IPC** -- `send`, `receive`, `sendrec`
- **Resident object catalog** -- programs cataloged at build time, not
  loaded from a filesystem
- **UART-hosted virtual timer** -- preemptive scheduling via heartbeat
  frames from the host terminal, with cooperative fallback
- **No MMU required** -- single address space with logical process
  isolation (separate stacks, no shared writable globals)
- **No hardware multiply or floating point required**
- **Entire system is one flat binary** -- kernel, services, and apps
  compiled and linked together
- **Emulator-first** -- runs identically on hardware and in the emulator

## Architecture

```
+-----------------------------------+
| Applications                      |
+-----------------------------------+
| Resident Services (tty, shell)    |
+-----------------------------------+
| SWTOS Microkernel                 |
|   scheduler, IPC, timers, heap    |
+-----------------------------------+
| COR24 HAL                         |
|   UART, GPIO, SPI, I2C            |
+-----------------------------------+
```

## Documentation

See [docs/plan.md](docs/plan.md) for the full development plan including
design philosophy, memory map, kernel subsystems, UART heartbeat protocol,
resident catalog design, milestones, and risk assessment.

## Building

Requires the PL/SW toolchain (compiler, assembler, and linker):

- [sw-cor24-plsw](https://github.com/sw-embed/sw-cor24-plsw) -- PL/SW compiler
- `cor24-asm` -- COR24 assembler
- `link24` -- FIXUP-based linker
- `meta-gen` -- cross-module symbol and FIXUP metadata generator

```
just build
```

The resident catalog is generated from `catalog/catalog.toml`. To regenerate
it and verify that the checked-in PL/SW descriptor table is current and
compiles into the complete system image:

```
just catalog-smoke
```

Boot initializes that table and scans its flags rather than naming the shell
entry directly. To verify metadata-driven `IMAGE_AUTOSTART` dispatch:

```
just autostart-smoke
```

The interactive shell retains choices `0` through `3` and also accepts
`run <name>`, for example `run counter`, plus `ls` to enumerate every resident
program and service. Lookup scans program descriptors by name and dispatches
the linked resident entry. Verify lookup and listing with:

```
just catalog-run-smoke
just catalog-list-smoke
```

The scheduler-side catalog spawn proof separately compiles and links a PL/SW
resident task with the assembly kernel, consumes descriptor stack/state sizes,
allocates private EBR regions, and launches two contexts sharing that PL/SW
entry point:

```
just catalog-spawn-smoke
```

The expected task output is `A1`, `B1`, `A2`, `B2`, demonstrating independent
zero-initialized state for both instances. An assembly trampoline translates
the scheduler's initial `r0` state pointer into the normal PL/SW stack calling
convention. Boot starts only task A; while its PL/SW frames are live, it calls
the exported `TASK_SPAWN(descriptor)` service with a descriptor pointer held in
private state to create task B, then both tasks call back into the scheduler to
yield.

The scheduler-integrated persistent PL/SW menu supports `1: Hello`,
`2: Counter`, `3: Clock`, and `0: Exit`. Hello waits for a key in its own
process; Counter prints `B1` and `B2`; Clock logs `mm:ss` from host UART
heartbeats until Ctrl-]. Each app exits, releases its process slot, and returns
to the preserved menu context:

```
just scheduled-shell-smoke
just scheduled-shell-interactive
```

Its `ls` command walks the generated scheduler descriptor table, and
`run <name>` searches that same table for program descriptors. A scheduler
join service keeps the shell suspended until the selected app exits, so adding
a cataloged program does not require a shell name branch or guessed yield
count. `TASK_EXIT` also restores the app slot's saved EBR arena pointer,
reclaiming its private state and stack as one LIFO allocation. Verify repeated
reuse with `just scheduled-reclaim-smoke`.

The scheduler scans a contiguous three-entry process table rather than
switching between hardcoded A/B descriptors. Two child slots can run
concurrently; `just scheduled-multislot-smoke` launches two Counter instances
and verifies round-robin `B1 C1 B2 C2` output from independent private state.
Their allocation generation is reclaimed when its last child exits.

The heartbeat-aware frontend accepts `--image`, so the same byte stuffing,
Ctrl-] translation, and line-ending filtering serve both the compatibility and
scheduler-integrated images. The latter is ready to become the primary demo.

Produces a flat binary image (.lgo) loadable via the COR24 serial boot
protocol at 921,600 baud.

To compile and run the SWTOS menu interactively in the emulator:

```
just plsw-system-interactive
```

This is now the scheduler-integrated image: Hello, Counter, and Clock run as
descriptor-backed processes with private stacks/state and return to the
persistent menu through `TASK_EXIT`. The shell also accepts `ls` and
`run hello`, `run counter`, or `run clock`. `just plsw-system-run` remains an
alias.
The terminal wrapper supplies timestamped UART heartbeats while Clock is
active. Choose `3` to log uptime as `mm:ss` once per second, and press Ctrl-]
to return to the menu. The wrapper translates that key because Ctrl-] is
reserved by the emulator terminal itself.

The former direct-call image remains available as a compatibility reference:

```
just plsw-system-compat-interactive
```

Scheduled command coverage is available with `just scheduled-catalog-smoke`.
Catalog generation emits both `include/catalog_generated.msw` and
`hal/cor24/catalog_generated.s`; the direct-call and scheduled images therefore
share names, kinds, entry metadata, stack/state sizes, and flags from one TOML
manifest.

To test the Clock app without an interactive terminal:

```
just clock-smoke
```

To verify separate PL/SW compilation and linking:

```
just plsw-link-smoke
```

This independently compiles an entry module and a library module, performs
two-pass assembly, applies cross-module FIXUPs with `link24`, and checks the
linked program's emulator output.

To exercise the cooperative COR24 context switch:

```
just context-switch-smoke
```

The test creates two task contexts on disjoint EBR stacks, alternates them
through `yield`, verifies saved register sentinels, and requires the UART
sequence `A1`, `B1`, `A2`, `B2`, `A3`, `B3`.
The complete output begins with `SWTOS M1 C0`: `C0` records that no heartbeat
has synchronized the clock while cooperative scheduling and IPC remain live.
The same fallback proof has an explicit recipe:

```
just cooperative-fallback-smoke
```

The same executable also provides the first synchronous IPC proof:

```
just ipc-smoke
```

The TTY task starts first and blocks in `receive`. The client fills a fixed
seven-word `TTY_WRITE` message, blocks in `send`, and wakes the TTY task. The
TTY task copies the message to a private buffer, acknowledges the sender, and
produces the alternating output, then replies synchronously. The task code
calls reusable `send`, `receive`, and `sendrec` kernel entries using the PL/SW
stack calling convention.

To verify UART transport framing and the virtual clock arithmetic:

```
just heartbeat-smoke
```

The test distinguishes ordinary bytes from escaped `0xFF` data and heartbeat
control frames, then verifies a three-tick delta across the 24-bit wrap from
`0xFFFFFE` to `0x000001`. It also scans two sleeping entries with deadlines
two and three and verifies that both become runnable at monotonic tick three.
UART bytes are parsed one per interrupt, and a foreground-work sentinel proves
that `jmp (ir)` resumes interrupted execution.

## License

MIT -- see [LICENSE](LICENSE).
