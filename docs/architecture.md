# SWTOS Architecture

Copyright (c) 2026 Michael A Wright

## Purpose and scope

SWTOS is a small, emulator-first operating system for the 24-bit MakerLisp
COR24 processor. It combines a PL/SW shell and applications with a COR24
assembly kernel, cooperative scheduler, synchronous IPC, catalog, executable
loader, and peripheral HALs. The same target code is intended to run in the
Rust emulator and on a COR24-TB; only the device implementation changes.

This document describes the implemented architecture. The historical design
and milestone record remains in `docs/plan.md`.

## System layers

```text
PL/SW applications: Hello, Counter, Uptime, Clock, external images
PL/SW shell: menu, ls, ps, run <name>
Catalog and process services: lookup, spawn, join, exit
Kernel: cooperative scheduling, contexts, IPC, allocation, virtual time
COR24 HAL: UART, bit-banged SPI, I2C
Device: Rust emulator models or COR24-TB peripherals
```

The primary interactive system is not the direct-call `tests/system.plsw` image.
`scripts/catalog-spawn-link.sh` compiles the PL/SW application module, combines
it with `hal/cor24/catalog-spawn.s` and the HAL modules, and FIXUP-links them as
a flat binary. The persistent shell is the autostart process; selected programs
run in child process slots and return through `TASK_EXIT`.

## Build and link architecture

PL/SW compilation is hosted by COR24 itself. `tools/plsw.lgo` runs inside
`cor24-emu`; `scripts/plsw-pipeline.sh` sends includes and source through the
compiler's UART `FILE:`/`SOURCE:` protocol and extracts generated assembly.
`cor24-asm` produces object images and listings. Multi-module scheduled builds
then use `meta-gen` to derive exports and FIXUP records and `link24` to produce
an address-zero `program.bin`.

Generated inputs are part of the architecture:

- `catalog/catalog.toml` declares programs and services.
- `catalog/images/*.toml` declares nonresident executable images.
- `catalog/providers.toml` maps build modes to provider callbacks.
- `scripts/generate-catalog.py` emits PL/SW and COR24 descriptor tables.
- `scripts/cor24-image.py` constructs versioned executable blobs.
- `scripts/cor24-storage.py` packs the authenticated media image.

Generated files must be reproducible. `just catalog-smoke` regenerates and
checks the catalog rather than treating checked-in output as authoritative.

## Boot and catalog dispatch

The catalog contains program and service descriptors with name, kind, entry,
stack size, state size, flags, and optional image metadata. Boot scans the
flags for `autostart`; it does not hardcode the shell name. The shell is also
`resident`, `single_instance`, and `privileged`.

The shell exposes numeric choices and catalog commands. `run <name>` resolves
a program descriptor and passes it to the same spawn service used by numeric
choices. `ls` enumerates generated descriptors, while `ps` walks the live
process table. A join suspends the shell until the selected child exits.

## Processes and scheduling

The scheduled kernel owns a contiguous three-slot process table: one preserved
shell slot and two child slots. Each 39-byte `PROC_DESC` contains thirteen
24-bit words. `hal/cor24/proc-desc.toml` is the canonical offset map and
`just proc-desc-abi-smoke` checks it against `include/swtos.msw` and kernel
allocation. No process-descriptor word is spare; offset 21 is `PD_SENDER`.

Spawn allocates descriptor-sized state and stack storage from an EBR arena,
initializes a context, and marks the child runnable. Tasks still switch cheaply
when they yield or block in kernel services. Private loaded processes also use
UART-clock-enforced time slicing: after a five-tick quantum and one-tick grace
period, a process that has not reached a normal scheduling point is forcibly
preempted.

COR24 cannot directly read the interrupt-return register. The forced path
therefore snapshots every live byte that it will overwrite, installs a private
landing jump after the live image, and temporarily replaces that image with
one-byte `add r0,r1` instructions. Returning through `ir` walks to the landing
slot while converting runway distance into the exact interrupted PC. The
kernel restores the live snapshot and later resumes through a patched `C7`
absolute-immediate jump after restoring all registers and condition state.
Mutable data should live outside the runway region in future image layouts;
with the current contiguous text/data/BSS layout the full live region is
snapshotted, so its runtime contents survive forced preemption.

Child allocations form a LIFO generation. State, loaded image, and stack are
reclaimed together after the last child in that generation exits. A failed
load rolls back its tentative allocation and leaves the slot reusable.

The EBR allocator enforces its 938-word installed window and records current
use, a high-water mark, and allocation failures. Spawn rolls back a generation
when stack or state allocation fails. The kernel also measures its painted boot
stack reserve before transferring control to the persistent shell. The shell's
`mem`, `mem -p`, and `mem -r` commands expose the image boundary, arena and
boot-stack measurements, per-process configured allocation, process-slot use,
and resettable counters. Physical capacity and process allocations are reported
in 24-bit words; packed build artifacts remain byte-sized.

Activity and preemption counters live in per-slot sidecars so the stable
39-byte process ABI does not change. Detailed process snapshots expose catalog identity, state,
blocked reason, configured allocation, scheduler dispatches and yields,
kernel-service/IPC operations, UART bytes, forced-preemption count, and the
last interrupted `r0` progress sample. The counters wrap naturally at
the unsigned 24-bit word boundary. Dispatch activity is not CPU time.

Four fixed virtual-TTY records provide endpoint-owned input queues without
expanding `PROC_DESC`. Each queue holds sixteen bytes and counts overflow.
An empty read sets `PROC_BLOCKED_TTY`; the scheduler polls the recovery UART
only for the blocked foreground owner, enqueues one byte, and wakes that owner.
Foreground ownership follows a newly spawned child and falls back to another
live child before returning to the shell. Output remains serialized through
the kernel UART path until the framed multiplexed transport is introduced.

## IPC

The kernel implements synchronous `send`, `receive`, and `sendrec` with fixed
messages. A sender blocks until a receiver accepts its message; the receiver
can block waiting for an endpoint. Process descriptors retain endpoint and
sender/wait state. The TTY proof uses this path rather than shared application
globals and validates blocking and wakeup across context switches.

## Image-provider contract

An image provider is a two-word record:

```text
word 0: find callback
word 1: arbitrary-byte read callback
```

The memory provider searches resident descriptors and reads compiled-in image
bytes. Block, W25Q32 SPI, and SD implementations preserve the same read
contract. The composite provider tries resident lookup first and prepares its
configured external provider only on a miss.

Composite lookup publishes the concrete read callback in
`_composite_lookup_read`. Spawn immediately copies that callback into a
sidecar word belonging to the selected child. Nonresident descriptors are
likewise copied into a 24-byte child-owned sidecar. These records deliberately
live outside both the fixed process ABI and fixed catalog descriptor ABI.

During synchronous loading, `_embedded_bound_read` routes every magic, header,
payload, and checksum read through the captured callback. It is cleared on
success and failure. A later lookup may change the transient composite result
without changing a live child's descriptor or source ownership.

## Executable and storage formats

C24IMG version 1 starts with a 27-byte header containing the six-byte magic,
version, text/data/BSS word counts, entry offset, relocation count, and payload
CRC. The loader requires nonzero text, an entry inside text, safe 24-bit size
arithmetic, exact descriptor extent agreement, successful bounded reads, and a
matching CRC before making the entry runnable. It copies text/data, clears BSS,
and records the relocated entry.

The storage image uses eight-byte blocks. Its header contains count, version,
`SWT`, and the low 24 bits of standard CRC-32 over fixed 24-byte catalog
records. Each record has a 16-byte NUL-terminated name, descriptor ordinal,
image offset, logical image length, and flags. Validation rejects malformed
names, record regions, ordinals, alignment, wrapping extents, capacity excess,
short reads, and corrupt checksums.

W25Q32 access uses SPI mode 0 and command `03h`; an eight-byte cache avoids
repeated physical reads. SD uses the same logical provider over CMD17 reads and
a 512-byte sector cache. Therefore catalog authentication and C24IMG loading do
not contain media-specific branches.

## UART and virtual time

The multiplexed transport wire format and decoder recovery rules are specified
in `docs/protocol.md`. Its reusable Rust implementation lives in
`tools/te-rs/src/protocol.rs`, and the same incremental COR24 decoder is linked
as a separate module into each scheduled image. `te-rs --framed` sends HELLO;
an exact ACK switches TTY input, per-process output, uptime, and wall clock to
typed frames. Without that option, plain recovery and legacy time frames remain
unchanged.

`te-rs --windows` owns the local terminal's alternate screen and renders a
fixed two-by-two desktop from a dependency-free UI model. Each pane retains
bounded scrollback independently. A configurable command prefix changes focus,
cycles, zooms, displays help, or detaches; all non-prefix input is framed for
only the focused channel. A scoped screen guard and the existing termios guards
restore the cursor, alternate screen, serial settings, and local terminal on
normal exit, detach, transport loss, and errors. The PTY acceptance recipe
exercises both successful and failing teardown paths.

The Resources pane requests a type-8 snapshot four times per second. SWTOS
serializes allocator, process-sidecar, TTY, UART, and protocol-error counters as
a bounded record generation. The host replaces the pane only after receiving a
matching end record, marks data stale after one second, and clears published
data on disconnect. This prevents a partial response or reconnect from mixing
values sampled at different times, and keeps missing data distinct from zero.

Scheduled linking also writes `program.debug.json`. It combines the final map
and relocated module listings into symbols, generated-assembly source lines,
instruction/function boundaries, absolute variable locations, a full-image
SHA-256, and a target-reportable build ID. The build ID is CRC-32 truncated to
24 bits over immutable executable bytes before `_proc_table`; excluding mutable
process tables and CRC scratch state makes a running target's report stable.
The Debugger pane refuses symbolic operations until that identity matches, but
keeps explicitly raw register and memory inspection available.

The interactive frontend is `scripts/swtos-terminal.py`. It runs the emulator
behind a pseudo-terminal, forwards ordinary bytes, and recognizes when the
shell has printed its `#` prompt. If a numeric choice is followed by Return, the
frontend discards that one CR/LF so it cannot be consumed by Hello or become a
new invalid menu choice.

While a time app is active, the frontend emits escaped time frames:

```text
FF 01 <tick-low> <tick-middle> <tick-high>
FF 00 encodes a literal FF payload byte
FF 03 encodes a literal 1D payload byte
```

Frame type `0x01` carries centiseconds since the frontend opened the terminal;
frame type `0x02` carries host-local centiseconds since midnight. Uptime and
Clock display these values respectively. Ticks are 24-bit centiseconds and may wrap.
deltas and prints `mm:ss` once per second. Ctrl-] is translated to target ESC
because the emulator reserves Ctrl-] for its own terminal control.

## Peripheral architecture

The I2C HAL bit-bangs the COR24 GPIO registers and supports START, repeated
START, byte transfer, ACK/NAK, and STOP. Current clients read a DS1307 RTC and
render its time through an SSD1306 OLED model. The SPI HAL bit-bangs MOSI,
MISO, clock, and active-low chip selects and serves both W25Q32 and SD devices.
Tests attach the emulator's Rust device models, inspect bus behavior, and also
exercise missing-device error paths.

## Verification boundaries

The smoke recipes are executable architectural claims. Important groups are:

- scheduler and IPC: `context-switch-smoke`, `ipc-smoke`,
  `scheduled-multislot-smoke`, and `scheduled-reclaim-smoke`;
- time and terminal: `heartbeat-smoke` and `clock-smoke`;
- formats and loading: `cor24-image-smoke`, `cor24-storage-smoke`, and
  `cor24-loader-smoke`;
- media providers: scheduled block, SPI, SD, composite, concurrent, and
  mixed-order recipes;
- devices: `i2c-ds1307-smoke`, `i2c-oled-clock-smoke`, and
  `spi-sdcard-smoke`.

`just emulator-acceptance` is the aggregate emulator gate. Its runner invokes
the canonical noninteractive recipes one at a time, preventing shared storage
corruption fixtures from racing under a parallel outer build. It emits a
versioned JSON report containing repository provenance, hashed tool identities,
UTC timing, and per-recipe outcomes; the failure path writes the completed
prefix before returning the failing recipe's status.

The hardware handoff builder treats that report as an input artifact. It
accepts only a complete passing report for the current clean commit and branch,
then copies and hashes the JSON beside the resident, SPI, seed, and storage
images. This binds emulator evidence to the source revision used for the
handoff without claiming physical validation.

The emulator is the normal development and acceptance environment. Physical
hardware validation is a separate final boundary because it requires a board,
UART adapter, and external loader. See `docs/hw-validation.md`.
