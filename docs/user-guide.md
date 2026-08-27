# SWTOS User Guide

Copyright (c) 2026 Michael A Wright

## What you can run

SWTOS provides a scheduler-integrated menu in the COR24 emulator. Its resident
applications are Hello, Counter, Uptime, and Clock. The shell also lists catalog
entries, reports process slots, and can load PL/SW applications from emulated
W25Q32 flash or SD media.

Run commands from the repository root.

## Prerequisites

Install `just`, Python 3, and the repository's COR24/PL/SW toolchain. These
files must exist:

```text
tools/plsw.lgo
tools/bin/cor24-asm
tools/bin/cor24-emu
tools/bin/cor24-dbg
tools/bin/meta-gen
tools/bin/link24
```

`plsw.lgo` is the PL/SW compiler itself and runs inside the emulator. The
pipeline therefore needs both the compiler image and emulator even when the
program being built is PL/SW. `just --list` shows all available recipes.

Start with these checks:

```sh
just plsw-smoke-run
just catalog-smoke
```

The first compiles, assembles, and runs a small PL/SW program. The second
regenerates the catalog, builds the system, and verifies generated files are
current.

## Run the primary interactive menu

```sh
just plsw-system-interactive
```

`just plsw-system-run` is a backward-compatible alias for the same scheduled
system. Wait for `Choice: `, then use:

| Input | Result |
|---|---|
| `1` | Run Hello; press a key when prompted to return |
| `2` | Run Counter and print its sequence |
| `3` | Run Uptime, measured from terminal connection |
| `4` | Run Clock, synchronized to the host's local wall time |
| `5` | Spawn two cooperative workers and show `B1 C1 B2 C2` |
| `ls` + Return | List catalog programs and services |
| `dir` + Return | Use the CP/M-style alias for `ls` |
| `ps` + Return | Show process slots and their states |
| `ps -l` + Return | Show detailed activity for every process slot |
| `help` + Return | List shell commands |
| `df` + Return | Show generated catalog and image totals |
| `du` + Return | Show generated external-image sizes |
| `stat NAME` + Return | Show catalog metadata for one entry |
| `stat ENDPOINT` + Return | Show detailed activity for endpoint 1, 2, or 3 |
| `uname` + Return | Print the SWTOS target and version |
| `run hello` + Return | Spawn a resident program by catalog name |
| `run counter` + Return | Spawn Counter by catalog name |
| `run uptime` + Return | Spawn Uptime by catalog name |
| `run clock` + Return | Spawn Clock by catalog name |

For numeric choices, either type the digit alone or type digit plus Return.
The terminal wrapper filters the optional line ending at the menu boundary so
it is not mistaken for Hello's keypress or a later menu choice.

Uptime prints `mm:ss` since the terminal connected; re-entering it does not
reset the count. Clock prints host local time as `HH:MM:SS`.

Press Ctrl-] to return to the menu. The wrapper translates it into the app's
ESC byte and continues running the shell. A literal Escape sent by another
frontend has the same target-side meaning.

To leave an emulator session that is not accepting menu input, use the
emulator's own terminal escape or interrupt the host command. Your terminal
settings are restored by the wrapper on exit.

## Run applications from emulated SPI flash

```sh
just plsw-system-spi-interactive
```

This builds the authenticated storage image, attaches it to the emulator as a
W25Q32 device, and starts the resident-first composite shell. Try:

```text
ls
run embedded-hello
run embedded-ping
run counter
```

Expected application markers are `E`, `P`, and Counter output respectively.
Resident commands do not touch flash; unknown resident names fall through to
the external catalog.

## Run applications from emulated SD

```sh
just plsw-system-sd-interactive
```

The commands are the same as for SPI. The storage bytes and loader contract are
also the same; only the provider read callback changes. The SD implementation
uses CMD17 and caches one 512-byte sector.

## Compatibility image

```sh
just plsw-system-compat-interactive
```

This runs the earlier monolithic direct-call PL/SW image. Keep it for comparison
and compatibility work. Use `plsw-system-interactive` for normal menu and
scheduler testing because it gives applications private process state, stacks,
join/exit behavior, and allocation reclamation.

## Build your own PL/SW program

Compile a standalone source file:

```sh
just plsw-compile path/to/program.plsw
```

Compile and run it:

```sh
just plsw-run path/to/program.plsw
```

Pass `.msw` includes before the main `.plsw` file:

```sh
just plsw-run include/example.msw path/to/program.plsw
```

Outputs are placed in `build/` as generated `.s`, assembled `.lgo`, and flat
`.bin` files. Include order matters because PL/SW declarations must be known
when referenced.

Do not feed compiler source with the emulator's short `-u` option. The supplied
pipeline uses `--uart-file`, which preserves the compiler's `FILE:`/`SOURCE:`
protocol without losing characters.

## Add a resident catalog application

1. Add the PL/SW procedure and declarations to an appropriate `.msw` module.
2. Include that module in the relevant PL/SW build.
3. Add a `[[program]]` entry to `catalog/catalog.toml` with its entry,
   scheduled trampoline, stack words, state words, and flags.
4. Regenerate and validate with `just catalog-smoke`.
5. Exercise it through `run <name>` and add a deterministic smoke test.

Use `single_instance` when a program cannot safely have two live instances.
Use `resident` only when its executable entry is linked into the system image.
Do not add private fields to `PROC_DESC`; its 39-byte ABI is full.

### Memory inspection

The scheduled shell reports runtime memory accounting with:

```text
mem
mem -p
mem -r
```

`mem` prints physical capacity, linked-image words, current and peak process
arena use, the measured boot/kernel-stack peak, estimated free words,
allocation failures, and occupied process slots. `mem -p` prints the configured
stack and state allocation for each live endpoint. `mem -r` resets the arena
high-water mark to current use and clears the allocation-failure counter; it
does not erase the boot-stack measurement. Values are COR24 24-bit words unless
the field explicitly says bytes.

### Process activity

Use `ps -l` for all slots or `stat 1`, `stat 2`, and `stat 3` for one stable
endpoint. Each line includes catalog identity, process and blocked states,
configured stack/state words, scheduler dispatches and yields, IPC/kernel
service operations, and TTY input/output bytes. These unsigned 24-bit counters
wrap after `16777215`; dispatch counts are activity indicators, not CPU time.

### Virtual terminals

The scheduled kernel owns four fixed virtual-TTY channels with sixteen-byte
input queues. Only the foreground process receives recovery-terminal input.
Readers with empty queues enter `BLOCKED_TTY` and stop accumulating scheduler
dispatches until input wakes them. When a foreground child exits, input focus
moves to another live child before returning to the shell.

## Add an external PL/SW application

External apps use a C24IMG manifest under `catalog/images/` and a catalog
program entry with `image_manifest`. The normal build discovers all declared
images, emits their assembly form, and packs them into
`build/catalog-images/swtos-storage.bin`.

Validate each layer:

```sh
just cor24-image-smoke
just cor24-storage-smoke
just cor24-loader-smoke
just scheduled-spi-provider-smoke
just scheduled-sd-provider-smoke
```

The loader checks magic, version, segment sizes, entry range, extent, bounds,
and CRC before execution. A load failure returns status to the shell and rolls
back the child allocation; an invalid image must never reach its entry point.

## Test groups

Run the complete noninteractive emulator acceptance gate before a release or
hardware handoff:

```sh
just emulator-acceptance
```

The runner prints and executes each canonical recipe sequentially. To inspect
its scope without building anything, run
`./scripts/emulator-acceptance.sh --list`.

The default machine-readable result is
`build/emulator-acceptance/report.json`. It records the Git commit and branch,
whether tracked files differed from that commit, host details, versions or
SHA-256 identities for the toolchain, overall UTC timing, and every completed
recipe's status, exit code, and duration. A failed recipe still produces the
partial report before the gate exits nonzero. Select another output path with:

```sh
./scripts/emulator-acceptance.sh --report path/to/report.json
```

For release evidence, commit intended source changes first and run the gate
from a clean tracked worktree so `tracked_worktree_dirty` is `false`.

`just hardware-validation-bundle` consumes that default report rather than
rerunning the gate. It rejects evidence from another commit or branch, dirty or
failed runs, incomplete recipe manifests, and a currently dirty tracked
worktree. The accepted JSON is copied into the bundle and covered by its
`SHA256SUMS` file.

Use focused tests while developing:

```sh
# Menu input, heartbeat, and Clock
just clock-smoke
just heartbeat-smoke

# Scheduler, IPC, slots, and reclamation
just context-switch-smoke
just ipc-smoke
just scheduled-multislot-smoke
just scheduled-reclaim-smoke

# Catalog and ABI
just catalog-smoke
just proc-desc-abi-smoke
just provider-config-smoke

# External providers
just scheduled-composite-spi-smoke
just scheduled-composite-sd-smoke
just scheduled-concurrent-spi-smoke
just scheduled-concurrent-sd-smoke
just scheduled-composite-sd-mixed-smoke
just scheduled-composite-sd-mixed-reverse-smoke

# Peripheral clients and emulator devices
just i2c-ds1307-smoke
just i2c-oled-clock-smoke
just spi-sdcard-smoke
```

Run recipes that build `swtos-storage.bin` sequentially. Several storage tests
intentionally corrupt or truncate a shared fixture during negative cases, so
parallel invocations can interfere with one another even when the target code
is correct. `just emulator-acceptance` enforces this sequencing internally.

## Troubleshooting

### The menu repeats `Invalid choice`

Use `just plsw-system-interactive`, not a raw emulator terminal command. The
wrapper detects the menu prompt and filters the optional newline after numeric
choices. Confirm the terminal recipe was rebuilt after source changes.

### Hello returns without a key

A queued CR or LF is being delivered to Hello. The supported wrapper removes
the newline immediately following a numeric menu choice. Type `1` once at the
`Choice: ` prompt and avoid piping an extra line of input into the session.

### Counter returns to repeated invalid choices

This also indicates leftover line endings or scripted input sent without prompt
synchronization. Use the interactive wrapper or the repository smoke scripts,
which wait for target output before sending the next byte sequence.

### Uptime or Clock does not advance

Both time apps require control frames from `scripts/swtos-terminal.py` or
`scripts/swtos-hardware-terminal.py`; an ordinary UART terminal does not supply
them. Uptime uses connection elapsed time and Clock uses host local wall time.
The Rust hardware frontend provides the same protocol:

```sh
cargo run --release --manifest-path tools/te-rs/Cargo.toml -- --swtos DEVICE
```
Add `--framed` for negotiated checksummed TTY and clock multiplexing. Omit it
to retain the plain recovery transport; the host does not switch until SWTOS
returns an exact HELLO acknowledgment.

Use `--windows` for the fixed four-pane desktop. It implies framed mode and
opens Shell, Application, Debugger, and Resources panes with independent
scrollback. The focused pane is marked with `*` and exclusively receives
ordinary keys. The default host prefix is Ctrl-A: follow it with `1` through
`4` to focus a pane, `n` to cycle, `z` to zoom, `?` for help, or `d` to detach.
Set another single-byte prefix with `--prefix KEY` or control notation such as
`--prefix '^B'`. Ctrl-] remains ordinary target input unless selected as the
host prefix.

Enter pane scrollback with Ctrl-A then `y`. Arrow keys or `h`/`j`/`k`/`l`
scroll left/down/up/right, Page Up and Page Down (or `u`/`d`) move ten lines,
`g` jumps to the oldest retained output, `G` returns to live output, and `q`
leaves copy mode. These navigation keys are consumed by the frontend and are
not sent to the target.

Use Ctrl-A then `e` to send an unambiguous Escape byte to the focused Shell or
Application pane, including while copy mode is active. This stops interactive
applications such as Uptime without conflicting with arrow-key escape
sequences.

The Resources pane refreshes at four Hz and shows memory current/peak use,
kernel-stack peak, allocation failures, live process state and activity, IPC
and TTY totals, UART traffic, and protocol errors. Per-process `fp=` counts
forced quantum recoveries and `cpu=` shows the last interrupted `r0` sample.
Run `cpu-hog` to see both change while verifying that the Debugger and Shell
remain responsive. `STALE` means no complete
snapshot has arrived for one second; `resource data unavailable` means no
complete generation has been received since connecting.

Pass `--debug-map build/NAME/program.debug.json` with `--windows` to enable
symbolic inspection in the Debugger pane. Focus it with Ctrl-A then `3` and use
`sym NAME`, `list NAME|ADDRESS`, or `dis NAME|ADDRESS [COUNT]`. These commands
remain disabled until the target's reported build ID matches the map. `regs
[ENDPOINT]` and `x ADDRESS [1..12]` are raw read-only operations and remain
available after a mismatch. `bl` lists breakpoints; `delete N` reports that
execution control arrives in the next saga.

Every scheduled build emits `program.debug.json` beside `program.bin` and
`program.lgo`. Validate deterministic debug metadata with `just
debug-info-smoke`.

For a checksummed hardware upload, press Ctrl-R and enter the `.lgo` path. The
uploader always drains the monitor echo to keep RTS/CTS flowing; add `--sync`
to validate every echoed byte. The validated COR24-TB settings are
`--sync --byte-delay 100 --delay 10`.
Run the primary interactive recipe and keep the wrapper active.

### An external application is not found

Confirm it is declared in `catalog/catalog.toml`, regenerate with
`just catalog-smoke`, and use the SPI or SD interactive recipe. The resident
interactive image has no attached external media.

### A tool is missing

Check the exact paths in Prerequisites. `just install-tools` only prints the
toolchain location; it does not download dependencies. Refer to the PL/SW
toolchain repository named in the root README for its build procedure.

## Hardware deployment

Emulator testing does not require physical hardware. For a board validation
bundle run:

```sh
just hardware-validation-bundle
```

Use repository-owned scripts and `just` recipes whenever generating untracked
build or hardware artifacts. Do not infer a file format from a similarly named
tool in another checkout, manually append loader records, or reuse an older
artifact. `scheduled-shell-build` now creates both `program.bin` and the
complete `program.lgo`; `hardware-validation-bundle` copies and checksums the
loadable LGO files. The LGO converter verifies a byte-for-byte round trip,
preserves all-zero records for warm reloads, and requires exactly one explicit
entry record.

Then follow `docs/hw-validation.md` and complete the bundled
`VALIDATION-RESULT.md`. Hardware requires a COR24-TB, a
921,600-baud UART adapter with RTS/CTS, and a separate `loadngo`-compatible
uploader. The emulator's `--load-binary` option is not a board uploader.
