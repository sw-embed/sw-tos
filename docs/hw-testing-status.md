# COR24-TB hardware testing status

## Status

SWTOS has booted on a physical COR24-TB for the first time. The resident
scheduler, catalog shell, process listing, Hello task, and Counter task have
all run successfully. On 2026-08-21 the scheduler-integrated seven-entry image
was loaded on COR24-TB and both time applications were confirmed in hardware.
Uptime first displayed `00:05`, continued through `00:20`, and therefore used
time since terminal attachment rather than time since app entry. Clock synced
to host-local `09:59:06` and advanced once per second. Ctrl-] returned cleanly
to the menu from both applications.
The UART-only Multitask choice requires no external peripherals. On 2026-08-21,
choice `5` launched two workers on COR24-TB, printed the cooperative schedule
`B1 C1 B2 C2`, returned `READY`, and redisplayed the five-choice menu.

This is an initial engineering result, not yet a completed hardware acceptance
record. The SPI-backed catalog and external images have not been programmed or
tested on the board.

## Tested revision and artifact

- Repository commit: `d0eb0806719af681c0f3b62ef0eb3bff61d3c319`
- Branch: `main`
- Emulator acceptance: 33 of 33 recipes passed
- Resident flat image size: 10,461 bytes
- Resident image SHA-256:
  `e19100d80d71683a601f06ed4bf6d0ee2e4bcfe8c90535f9a01804801a43c1cd`
- Load address and entry address: `0x000000`
- Hardware transport: FTDI FT232R, 921600 baud, 8N1, RTS/CTS
- Stable serial path:
  `/dev/serial/by-id/usb-FTDI_FT232R_USB_UART_A50285BI-if00-port0`
- Uploader: the checksummed COR24 TE2 loader

The Multitask image was uploaded with the Rust terminal using 100-microsecond
byte pacing, 10-millisecond record pacing, and exact monitor-echo validation:

```sh
tools/te-rs/target/release/te-rs --swtos --sync \
  --byte-delay 100 --delay 10 DEVICE
```

The Rust uploader must consume the monitor's echoed records during every
upload, including without `--sync`; otherwise its receive queue fills, RTS is
deasserted, and the full-duplex hardware-flow-control path deadlocks.

The hardware-validation bundle passed every SHA-256 check before the resident
binary was wrapped in complete, zero-preserving L records. Decoding that LGO
back to bytes reproduced the bundled resident image exactly.

TE2 reported:

```text
verified: 581 records, CRC16=ECED
jump: 000000
SPAWN
MENU 1=Hello 2=Counter 3=Uptime 4=Clock
Choice:
```

## Resident hardware results

The following checks passed on the physical board:

- SWTOS booted and spawned the persistent shell.
- `ls` listed `hello`, `counter`, `clock`, `embedded-hello`,
  `embedded-ping`, and `shell`.
- `ps` reported shell endpoint 1 as `RUNNABLE` and endpoints 2 and 3 as
  `FREE`.
- Choice `1` printed `Hello` and `Press key`, remained blocked until a new
  key was sent, then printed `READY` and returned to the menu.
- Choice `2` printed `B1`, `B2`, and `READY`, then returned cleanly.
- Choice `3` printed `Clock` and `00:00`.
- Choice `5` printed `B1`, `C1`, `B2`, `C2`, and `READY`, then returned
  cleanly to the menu.

An initial `ls` attempt sent CR where the shell's short command parser requires
LF and correctly returned `BAD`. Sending LF produced the expected catalog.
This was a terminal integration issue rather than a target failure.

## Hardware terminal

Use `scripts/swtos-hardware-terminal.py` for manual SWTOS interaction over a
physical UART:

```sh
./scripts/swtos-hardware-terminal.py \
  /dev/serial/by-id/usb-FTDI_FT232R_USB_UART_A50285BI-if00-port0
```

The terminal:

- configures 921600 baud, 8N1, and RTS/CTS;
- translates target LF output to CRLF for correct raw-terminal display;
- translates typed CR to the LF expected by `ls` and `ps`;
- removes the optional newline typed after numeric menu choices so it cannot
  leak into a newly spawned application;
- locally echoes printable keystrokes because SWTOS does not echo UART input;
- displays `Escape` when Ctrl-] or literal ESC exits Clock;
- injects Uptime (`FF 01`) and Clock (`FF 02`) frames without displaying them;
- translates Ctrl-] to either time application's ESC exit byte; and
- uses Ctrl-C to exit the host terminal.

If the board or USB/UART adapter is powered down while the terminal is open,
the terminal reports that the serial device disconnected, restores the host
TTY, and exits without a Python traceback. Starting it while the stable device
path is absent similarly reports a concise `cannot open` diagnostic. Reconnect
the adapter and wait for its `/dev/serial/by-id/` link to reappear before
restarting the terminal.

If a previous frontend was stopped while SWTOS was already inside a time app,
reattach with:

```sh
./scripts/swtos-hardware-terminal.py --clock-active \
  /dev/serial/by-id/usb-FTDI_FT232R_USB_UART_A50285BI-if00-port0
```

Use `--uptime-active` in the corresponding recovery case. Time frames use:

- `FF 01 <escaped-24-bit-centiseconds>` for connection uptime;
- `FF 02 <escaped-24-bit-centiseconds>` for local time since midnight.

```text
FF 01 <24-bit centisecond tick, little-endian with byte stuffing>
```

Payload `FF` is encoded as `FF 00`, and payload `1D` is encoded as `FF 03`.
These control bytes are sent directly to the UART and are not rendered as user
terminal output.

## Remaining work

1. Exercise `run hello`, `run counter`, invalid catalog names, repeated task
   reuse, and Return-driven menu refresh on hardware.
2. Preserve a complete timestamped terminal transcript and fill out
   `VALIDATION-RESULT.md` for the resident phase.
3. Establish a verified W25Q32 programming and read-back procedure before
   beginning SPI-backed catalog acceptance.
4. Continue soak testing the Rust terminal in `tools/te-rs`; its `--swtos`,
   `--uptime-active`, and `--clock-active` modes now implement echo, time-frame
   byte stuffing, and Ctrl-] behavior and have been exercised on COR24-TB.
