# COR24-TB Hardware Validation

Emulator acceptance is complete. Physical validation requires a COR24-TB,
its serial loader, and a USB/UART adapter that sustains 921,600 baud with
RTS/CTS hardware flow control. No suitable serial device or loader is bundled
with this repository.

## Prepare artifacts

Run:

```sh
just emulator-acceptance
just hardware-validation-bundle
```

The bundle command does not rerun acceptance. It requires the default JSON
report from a passing gate run on the current commit and branch, with both the
reported and current tracked worktrees clean and the complete current recipe
manifest present. Stale, failed, dirty, or incomplete evidence is rejected.

This creates `build/hardware-validation/` containing:

- `swtos-resident.bin`: scheduler-integrated resident menu at address zero.
- `swtos-spi.bin`: composite resident/SPI shell at address zero.
- `swtos-spi-seed.lgo`: emulator launch workaround; retain as reference unless
  the board loader specifically requires an LGO container.
- `swtos-storage.bin`: 30-block W25Q32 image containing the authenticated
  catalog and both nonresident applications.
- `emulator-acceptance.json`: exact emulator recipe results, timing,
  repository provenance, and tool identities for this source revision.
- `SHA256SUMS`: exact identities for all five artifacts.

Verify the bundle before programming:

```sh
cd build/hardware-validation
shasum -a 256 -c SHA256SUMS
```

Also confirm `emulator-acceptance.json` reports `status: "pass"`, the expected
commit, `tracked_worktree_dirty: false`, and a 33/33 passing summary before
transferring the bundle to the hardware operator.

## Connection gate

Before upload, confirm all of the following:

1. The COR24-TB and its UART adapter appear as a real `/dev/cu.*` device.
2. UART is configured for 921,600 baud and RTS/CTS hardware flow control.
3. TX, RX, ground, RTS, and CTS are connected with the correct voltage level.
4. The established COR24 `loadngo`-compatible loader is available. Record its
   version and full command line in the validation result.

Do not substitute the emulator's `--load-binary` option for a board uploader;
it implements no host serial transport.

## Resident acceptance

Load `swtos-resident.bin` at address zero and start at address zero. Record the
board/FPGA revision, adapter, serial device, loader version, artifact checksum,
and terminal transcript. The transcript must demonstrate:

1. Menu startup and `ls`/`ps` output.
2. Choice `1`: Hello waits for input and returns only after a key.
3. Choice `2`: Counter prints `B1`, `B2`, and returns to the menu.
4. Choice `3`: Clock prints increasing `mm:ss`; Ctrl-] returns to the menu.
5. Choice `0`: the shell prints `BYE`.

## SPI acceptance

Program `swtos-storage.bin` at W25Q32 offset zero, load `swtos-spi.bin` at
address zero, and start at zero. In addition to the resident checks, run:

```text
run embedded-hello
run embedded-ping
run counter
```

Require `E`, `P`, `B1`, and `B2`, with the menu returning after each command.
Read back the programmed flash range and compare it byte-for-byte with
`swtos-storage.bin` before treating a failure as an SWTOS loader defect.

## Current external blocker

On 2026-08-11 the development host exposed only Bluetooth and debug-console
serial endpoints. Physical acceptance cannot be claimed until a COR24-TB UART
device and the board's loader are supplied.
