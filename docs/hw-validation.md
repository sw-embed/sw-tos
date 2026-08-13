# COR24-TB Hardware Validation Plan

Copyright (c) 2026 Michael A Wright

## Objective

This procedure validates that an emulator-accepted SWTOS revision boots and
operates on a physical COR24-TB, first from resident SRAM and then with
nonresident applications stored in W25Q32 flash. Emulator success is a required
entry condition, not a substitute for board evidence.

The operator must preserve the completed `VALIDATION-RESULT.md`, terminal
transcripts, read-back image, and original bundle together. A run is accepted
only when every required check passes or is explicitly marked not applicable
with a reason approved by the project owner.

## Required equipment and software

- COR24-TB with board and FPGA revisions known.
- Regulated power and the board's normal programming connection.
- 3.3 V-compatible USB/UART adapter supporting 921,600 baud and RTS/CTS.
- TX, RX, ground, RTS, and CTS connections verified against board pinout.
- Terminal capable of raw 8-bit operation without local echo or newline
  translation.
- Established COR24 `loadngo`-compatible uploader and its version information.
- W25Q32 programmer, or a loader command proven to program and read back the
  board's SPI flash at byte offset zero.
- `shasum` or another SHA-256 implementation for bundle verification.

The repository supplies target images and emulator tooling. It does not supply
the physical board uploader. Emulator `--load-binary` loads emulator memory and
must not be recorded as a hardware programming command.

## Phase 1: create the evidence-bound bundle

Commit all intended source changes, then run from a clean `main` checkout:

```sh
just emulator-acceptance
just hardware-validation-bundle
```

The first command executes the complete noninteractive emulator gate. The
second validates that its JSON report is passing, complete, from the current
commit and branch, and was generated with a clean tracked worktree. It does not
silently rerun acceptance.

The resulting `build/hardware-validation/` contains:

- `swtos-resident.bin`: scheduler-integrated resident menu, load address zero.
- `swtos-spi.bin`: resident-first/SPI-fallback shell, load address zero.
- `swtos-spi-seed.lgo`: emulator launch seed retained for reference; do not
  assume a board loader needs it.
- `swtos-storage.bin`: authenticated catalog and nonresident C24IMG payloads
  for W25Q32 byte offset zero.
- `emulator-acceptance.json`: source/tool provenance and all emulator results.
- `VALIDATION-RESULT.md`: result form to complete during this procedure.
- `SHA256SUMS`: identities of all six files above.

Before moving the bundle to another machine:

```sh
cd build/hardware-validation
shasum -a 256 -c SHA256SUMS
```

Inspect `emulator-acceptance.json`. Require `status` to be `pass`, summary to
show 33 passed and zero failed, the recorded commit to match the intended
revision, and `tracked_worktree_dirty` to be false. Copy the commit, report
time, and checksums into `VALIDATION-RESULT.md`.

Repeat the checksum verification on the hardware host. A transfer checksum
failure invalidates the bundle; replace it from the original rather than
continuing with an unexplained artifact.

## Phase 2: record the physical setup

Before powering or programming, record:

1. Date, operator, location, and result-file name.
2. COR24-TB board revision and serial/asset identifier.
3. FPGA image revision or bitstream identity.
4. USB/UART adapter make, model, voltage, and serial identifier.
5. Host OS, serial device path, and terminal command/settings.
6. Uploader name, version, and exact command lines.
7. W25Q32 programming and read-back method.

Confirm the UART is 921,600 baud, 8 data bits, no parity, one stop bit, and
RTS/CTS hardware flow control. Disable software flow control, local echo, and
host newline conversion. Verify common ground and voltage compatibility before
connecting TX/RX or powering the board.

## Phase 3: resident image acceptance

1. Load `swtos-resident.bin` at address `0x000000`.
2. Start execution at address `0x000000`.
3. Capture the complete terminal transcript from reset through exit.
4. At `Choice:`, run `ls` and require all catalog entries to be listed.
5. Run `ps` and require stable process endpoints and sensible slot states.
6. Choose `1`. Require `Hello from SWTOS!` and verify the app remains waiting
   until a new key is pressed; the Return used for the choice must not satisfy
   the app prompt.
7. Choose `2`. Require Counter output and a clean return to one menu prompt,
   with no repeating `Invalid choice` loop.
8. Choose `3`. Require `00:00` followed by increasing `mm:ss` values. Press
   Ctrl-] and require a return to the menu.
9. Choose `0` and require `BYE` or the documented clean shell termination.

Record each check as pass or fail. A reset, hang, unexpected prompt loop,
missing output, or input consumed by the wrong app is a failure even if later
steps appear to work.

## Phase 4: SPI storage acceptance

1. Program `swtos-storage.bin` into W25Q32 starting at byte offset zero.
2. Read back exactly the programmed length into a new file.
3. Compare the read-back file byte-for-byte with `swtos-storage.bin` and record
   both SHA-256 values. Do not diagnose target loading until this comparison
   passes.
4. Load `swtos-spi.bin` at address zero and start at address zero.
5. Repeat the resident menu checks needed to prove UART and resident dispatch.
6. Run `run embedded-hello`; require `E` and return to the menu.
7. Run `run embedded-ping`; require `P` and return to the menu.
8. Run `run counter`; require resident Counter output and return to the menu.
9. Repeat one external command to demonstrate reusable child allocation and
   stable flash access.
10. Exit cleanly and preserve the transcript.

The external applications and resident Counter must coexist behind the same
shell interface. A correct resident run does not compensate for a failed flash
read, catalog lookup, C24IMG check, or application return.

## Failure triage

Classify a failure before changing code:

- Bundle/provenance: acceptance validator or SHA-256 mismatch. Recreate the
  bundle; do not program it.
- Transport: no banner, corrupted characters, or flow-control stalls. Recheck
  voltage, ground, TX/RX orientation, baud, RTS/CTS, and terminal translation.
- Upload/start: no execution with otherwise working UART. Verify binary versus
  LGO format, load address, entry address, loader version, and reset sequence.
- Menu input: Hello exits from the choice newline or Counter causes invalid
  choices. Capture raw RX bytes and compare the terminal behavior with
  `scripts/swtos-terminal.py` filtering.
- Clock: menu works but time does not advance. Record whether the hardware host
  supplies the SWTOS heartbeat framing; ordinary UART input is not a clock.
- SPI media: resident image works but external commands fail. Require a clean
  flash read-back before investigating the target HAL or loader.
- Target defect: reproducible failure with verified transport, exact artifacts,
  correct addresses, and matching flash. Preserve the smallest transcript and
  full setup record needed to reproduce it in the emulator or on another board.

Never overwrite a failed transcript with a later successful attempt. Create a
new result record for each materially different setup, artifact, or retry.

## Completion criteria

A hardware validation is complete only when:

- the bundle and read-back checksums pass;
- the result form identifies the exact commit, artifacts, tools, board, loader,
  wiring/serial configuration, and commands;
- all resident and SPI checks pass with attached transcripts;
- any deviations and retries are recorded; and
- the operator signs and dates the final disposition.

Until then, project status remains “emulator accepted; physical validation
pending.”

