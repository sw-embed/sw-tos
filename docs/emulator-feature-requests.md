# Emulator requests from SWTOS

Things SWTOS wants from
[sw-cor24-emulator](https://github.com/sw-embed/sw-cor24-emulator), with the
evidence that produced them. Diagnosed from the emulator's own source at
`cli/src/run.rs`; no change was made to that repository.

---

## 1. Attach `--spi-device` and `--i2c-device` in binary mode

**Want:** the two run modes to act on the same flags.

**The bug.** `cor24-emu` chooses between a `"lgo"` arm and a `"binary"` arm.
The lgo arm ends with

```rust
load_binaries_and_patches(&mut emu, &cli.load_binaries, &cli.patches, cli.quiet);

attach_i2c_devices(&mut emu, &cli.i2c_devices);
attach_spi_devices(&mut emu, &cli.spi_devices);
```

and the binary arm has the first line and not the other two. So in binary mode
`--spi-device` is parsed, accepted, and dropped. Nothing is reported: the
program simply sees an empty bus.

```sh
# card attaches, listing works
cor24-emu --lgo seed.lgo --load-binary program.bin@0 --entry 0 \
    --spi-device "sdcard@cs=2?file=card.img" -u 'sdls\n' --quiet
    -> APPS <dir> / HELLO.TXT 22 / ...

# same flags, no seed: card silently absent
cor24-emu --load-binary program.bin@0 --entry 0 \
    --spi-device "sdcard@cs=2?file=card.img" -u 'sdls\n' --quiet
    -> no valid SD card detected
```

**Why it matters more than it looks.** The workaround is a stub `.lgo` whose
only purpose is to reach the arm that attaches devices --
`tests/spi-launch-seed.s` in SWTOS is two instructions, `_seed: bra _seed`, and
its comment says exactly that. But **the lgo arm never enters terminal mode**:
`run_terminal_mode` is called only from the binary arm, so `--terminal` is
accepted and ignored there. The emulator then narrates the UART instead of
bridging it --

```
[UART TX @ 10000] 'M'  (0x4D)
[UART TX @ 10000] 'u'  (0x75)
```

-- and typed input reaches nothing.

So today a peripheral and a keyboard are mutually exclusive: a seed buys the
card and costs the terminal. SWTOS can list an SD card only from a scripted
run, and `just plsw-system-spi-interactive` and `just plsw-system-sd-interactive`
have never been interactive despite their names.

**The fix, as tested locally and then reverted:** add the two `attach_*` calls
to the binary arm, after `load_binaries_and_patches`. Two lines. With them,

```sh
cor24-emu --load-binary program.bin@0 --entry 0 \
    --spi-device "sdcard@cs=2?file=card.img" -u 'sdls\n' --quiet
    -> APPS <dir> / README.TXT 17
```

and `--terminal` works in the same invocation, because binary mode already
supports it.

**Note on verifying.** `cargo build --release` at the workspace root does not
rebuild the CLI; it needs `-p cor24-cli`. A stale `target/release/cor24-emu`
made the fix look ineffective for one round of testing here.

**Note on the test suite.** `cargo test` currently reports 341 passed and 7
failed on a clean checkout of `main` at `8e22291`, before any change
(`test_stack_underflow_detected`, `test_echo_via_single_step_loop`,
`test_uart_log_echo_session`, `a_stack_outside_ebr_is_valid_when_the_bounds_say_so`,
`test_echo_via_challenge_source`, `test_stack_bounds_disabled`,
`test_stack_overflow_detected`). Worth a look independently of this request.

**Alternative, if binary mode should not grow peripherals:** have the lgo arm
honour `--terminal`. Either one removes the exclusivity; attaching in binary
mode is the smaller change and makes the two modes take the same flags, which
is what the help text already implies.

---

## 2. A 24-bit sector number reaches 8 GiB of a card

Not a request yet -- a ceiling worth recording. `SPI_SD_READ_SECTOR` in SWTOS
passes a 24-bit sector number, so 2^24 x 512 B = 8 GiB is addressable. FAT32
structures live near the start of a volume, so listing works on a card of any
size; file data beyond 8 GiB does not. Raising it is SWTOS's side of the work
(a two-word sector number through the SPI service), not the emulator's, unless
the SD device ever needs to report a capacity.
