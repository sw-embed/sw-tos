# Emulator requests from SWTOS

Things SWTOS wants from
[sw-cor24-emulator](https://github.com/sw-embed/sw-cor24-emulator), with the
evidence that produced them. Diagnosed from the emulator's own source at
`cli/src/run.rs`; no change was made to that repository.

---

## 1. Attach `--spi-device` and `--i2c-device` in binary mode

**One-line summary:** two calls are present in the `"lgo"` match arm and absent
from the `"binary"` arm, and only the binary arm can run a terminal. So a
peripheral and a keyboard are mutually exclusive, for no reason in the design.

### Where

`cli/src/run.rs`, at commit `8e22291`. The dispatch has three arms: `"demo"`
(line 1460), `"lgo"` (1503), `"binary"` (1595).

| | lgo arm | binary arm |
|---|---|---|
| `load_binaries_and_patches` | line 1559 | line 1615 |
| `attach_i2c_devices` | **line 1561** | **absent** |
| `attach_spi_devices` | **line 1562** | **absent** |
| `run_terminal_mode` | **absent** | line 1657 (sole call site) |

That table is the whole bug: the two capabilities are in different arms.

### The change

In the `"binary"` arm, after `load_binaries_and_patches` at line 1615 and
before the `if let Some(entry_str) = &cli.entry` that follows it, add the two
calls the lgo arm already makes:

```rust
            attach_i2c_devices(&mut emu, &cli.i2c_devices);
            attach_spi_devices(&mut emu, &cli.spi_devices);
```

Both helpers are already defined in this file (`attach_i2c_devices` at line
870, `attach_spi_devices` at 888) and take `(&mut EmulatorCore, &[String])`, so
nothing needs importing or moving. Placement matters only in that it must be
after the emulator is constructed; the lgo arm puts it after the loads and the
same order works here.

### Why it is safe

The two subsystems never touch each other. `attach_spi_devices` populates
`emu.spi().device`, which the guest program drives through memory-mapped
registers. `run_terminal_mode` bridges the host's stdin and stdout to the UART.
They share no state, and the guest reaching one does not involve the other.
There is no design reason a program cannot read a card and a keyboard at once
-- SWTOS already does exactly that on hardware.

### Verifying

With SWTOS built (`just scheduled-shell-build`, `just sd-card`):

```sh
# Before: the card is silently absent, because the flag was dropped.
cor24-emu --load-binary build/scheduled-shell/program.bin@0 --entry 0 \
    --stack-bounds 0x0F0000:0xFEEC00 \
    --spi-device "sdcard@cs=2?file=work/sd/swtos-card.img" \
    -u 'sdls\n' --speed 0 -n 60000000 --quiet
    -> no valid SD card detected

# After: the same command lists the card.
    -> APPS <dir> / DOCS <dir> / HELLO.TXT 22 / README.TXT 17

# And the point of the change -- the same run can take a keyboard, because
# binary mode is the arm that has run_terminal_mode:
cor24-emu --load-binary build/scheduled-shell/program.bin@0 --entry 0 \
    --stack-bounds 0x0F0000:0xFEEC00 \
    --spi-device "sdcard@cs=2?file=work/sd/swtos-card.img" \
    --terminal --quiet --speed 0
    then type: sdls
```

The first two were run here against a locally patched build and behaved as
shown; the change was then reverted, because this repository is not SWTOS's to
change. The third follows from binary mode already owning `run_terminal_mode`
and was not run, since it needs the change in place.

### Two things that cost time here

- **`cargo build --release` does not rebuild the CLI.** It reports success
  having compiled only `cor24-isa` and `cor24-emulator`, leaving a stale
  `target/release/cor24-emu`. The fix appeared not to work for a full round of
  testing because of it. Use `cargo build --release -p cor24-cli`.
- **The suite is red before any change.** On a clean checkout of `8e22291`,
  `cargo test` reports 341 passed and 7 failed: `test_stack_underflow_detected`,
  `test_echo_via_single_step_loop`, `test_uart_log_echo_session`,
  `a_stack_outside_ebr_is_valid_when_the_bounds_say_so`,
  `test_echo_via_challenge_source`, `test_stack_bounds_disabled`,
  `test_stack_overflow_detected`. Identical with and without the change, so it
  introduces no regression -- but a green baseline would make that easier to
  claim.

### A regression test worth adding

`parse_args()` reads `env::args()` directly, so argument handling cannot be
tested with a fixed argv without refactoring it to take a slice. That refactor
would make it possible to assert the thing that broke: that `--spi-device`
survives into `CliArgs` and is acted on from *both* arms. Until then the only
guard is end to end, which SWTOS now has in `just sd-listing`.

## 2. A 24-bit sector number reaches 8 GiB of a card

Not a request yet -- a ceiling worth recording. `SPI_SD_READ_SECTOR` in SWTOS
passes a 24-bit sector number, so 2^24 x 512 B = 8 GiB is addressable. FAT32
structures live near the start of a volume, so listing works on a card of any
size; file data beyond 8 GiB does not. Raising it is SWTOS's side of the work
(a two-word sector number through the SPI service), not the emulator's, unless
the SD device ever needs to report a capacity.
