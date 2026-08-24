# SWTOS COR24-TB Validation Result

Copyright (c) 2026 Michael A Wright

## Disposition

- Result: PENDING / PASS / FAIL / BLOCKED
- Date and time with timezone:
- Operator:
- Location:
- Notes or deviation approval:

## Source and emulator evidence

- Git commit:
- Branch:
- Emulator report started/ended UTC:
- Emulator summary:
- `tracked_worktree_dirty`:
- `emulator-acceptance.json` SHA-256:

## Hardware and host

- COR24-TB board revision:
- Board serial or asset ID:
- FPGA image/bitstream revision:
- Power supply:
- USB/UART adapter, voltage, and serial ID:
- Host OS and version:
- Serial device:
- Terminal application and exact command:
- UART: 921600 baud / 8N1 / RTS-CTS / software flow control off: YES / NO
- Wiring verified: TX / RX / GND / RTS / CTS / voltage: YES / NO
- Uploader name and version:
- W25Q32 programmer/read-back method:

## Bundle verification

- Hardware-host `shasum -a 256 -c SHA256SUMS`: PASS / FAIL
- `swtos-resident.bin` SHA-256:
- `swtos-resident.lgo` SHA-256:
- `swtos-spi.bin` SHA-256:
- `swtos-spi.lgo` SHA-256:
- `swtos-spi-seed.lgo` SHA-256:
- `swtos-storage.bin` SHA-256:
- `emulator-acceptance.json` SHA-256:
- `VALIDATION-RESULT.md` original-template SHA-256:

## Commands

Record exact commands, including devices, addresses, and options.

```text
resident upload/start:

flash program:

flash read-back:

SPI image upload/start:

terminal capture:
```

## Resident acceptance

| Check | Result | Evidence/notes |
|---|---|---|
| Boot banner and menu | PENDING | |
| `ls` catalog listing | PENDING | |
| `ps` process listing | PENDING | |
| Hello waits for a new key | PENDING | |
| Counter returns without invalid-choice loop | PENDING | |
| Clock advances in `mm:ss` | PENDING | |
| Ctrl-] returns from Clock | PENDING | |
| Return reports BAD and refreshes menu | PENDING | |

- Transcript file and SHA-256:

## SPI acceptance

| Check | Result | Evidence/notes |
|---|---|---|
| Flash read-back byte-for-byte comparison | PENDING | |
| SPI shell boots | PENDING | |
| `run embedded-hello` prints `E` and returns | PENDING | |
| `run embedded-ping` prints `P` and returns | PENDING | |
| `run counter` remains resident and returns | PENDING | |
| Repeated external run succeeds | PENDING | |
| Shell exits cleanly | PENDING | |

- Programmed length:
- Flash read-back file and SHA-256:
- Expected storage SHA-256:
- Transcript file and SHA-256:

## Failures and retries

For each attempt record timestamp, observed behavior, classification, setup or
artifact change, and whether a new transcript/result record was created.

```text
none / details:
```

## Sign-off

- Final disposition:
- Operator signature/name:
- Date:
- Project-owner review:
