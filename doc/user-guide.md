# SWTOS User Guide

Copyright (c) 2026 Michael A Wright

## What you can run

SWTOS provides a scheduler-integrated menu in the COR24 emulator. Its resident
applications are Hello, Counter, and Clock. The shell also lists catalog
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
| `3` | Run Clock and print uptime once per second |
| `0` | Exit the shell |
| `ls` + Return | List catalog programs and services |
| `ps` + Return | Show process slots and their states |
| `run hello` + Return | Spawn a resident program by catalog name |
| `run counter` + Return | Spawn Counter by catalog name |
| `run clock` + Return | Spawn Clock by catalog name |

For numeric choices, either type the digit alone or type digit plus Return.
The terminal wrapper filters the optional line ending at the menu boundary so
it is not mistaken for Hello's keypress or a later menu choice.

Clock initially prints `00:00`. Press Ctrl-] to return to the menu. The wrapper
translates Ctrl-] into the app's ESC byte and continues running the shell. A
literal Escape sent by another frontend has the same target-side meaning.

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

### Clock does not advance

Clock requires heartbeat frames from `scripts/swtos-terminal.py`. It will print
`00:00` without synchronization but cannot advance from ordinary UART input.
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

Then follow `docs/hardware-validation.md`. Hardware requires a COR24-TB, a
921,600-baud UART adapter with RTS/CTS, and a separate `loadngo`-compatible
uploader. The emulator's `--load-binary` option is not a board uploader.
