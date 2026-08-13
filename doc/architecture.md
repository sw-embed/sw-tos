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
PL/SW applications: Hello, Counter, Clock, external images
PL/SW shell: menu, ls, ps, run <name>
Catalog and process services: lookup, spawn, join, exit
Kernel: cooperative scheduling, contexts, IPC, allocation, virtual time
COR24 HAL: UART, bit-banged SPI, I2C
Device: Rust emulator models or COR24-TB peripherals
```

The primary interactive system is not the direct-call `system.plsw` image.
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
initializes a context, and marks the child runnable. Context switching is
cooperative: tasks yield or block in kernel services. Current COR24 interrupt
state cannot be saved and restored for a different process, so heartbeat
interrupts update time but do not provide full preemption.

Child allocations form a LIFO generation. State, loaded image, and stack are
reclaimed together after the last child in that generation exits. A failed
load rolls back its tentative allocation and leaves the slot reusable.

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

The interactive frontend is `scripts/swtos-terminal.py`. It runs the emulator
behind a pseudo-terminal, forwards ordinary bytes, and recognizes when the
shell has printed `Choice: `. If a numeric choice is followed by Return, the
frontend discards that one CR/LF so it cannot be consumed by Hello or become a
new invalid menu choice.

While Clock is active, the frontend emits escaped heartbeat frames:

```text
FF 01 <tick-low> <tick-middle> <tick-high>
FF 00 encodes a literal FF payload byte
FF 03 encodes a literal 1D payload byte
```

Ticks are 24-bit centiseconds and may wrap. Clock derives elapsed uptime from
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
corruption fixtures from racing under a parallel outer build.

The emulator is the normal development and acceptance environment. Physical
hardware validation is a separate final boundary because it requires a board,
UART adapter, and external loader. See `docs/hardware-validation.md`.
