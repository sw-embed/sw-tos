# Use cases and the proofs that hold them

What a person does with SWTOS, and which acceptance recipe fails if it stops
working. Every recipe here runs in `just emulator-acceptance`; a use case with
no recipe is listed as a gap rather than left implied.

Run one with `just <recipe>`.

## Starting and stopping programs

| Use case | How | Recipe |
| --- | --- | --- |
| See what programs exist | `ls`, `stat <name>`, `df`, `du` | `scheduled-catalog-smoke` |
| Run a program in its own pane | `run <name>` | `debugger-kill-acceptance`, `scheduled-shell-smoke` |
| Start a program without blocking the prompt | `bg <name>` (same as `run`) | `test-shell-command-parsing`, `catalog-run-smoke` |
| Launch from the menu | keys `1`-`6` | `scheduled-shell-smoke` |
| Fill every process slot | menu `9` | `fill-demo-acceptance`, `scheduled-sixteen-smoke` |
| Refuse a spawn with no free slot | `run` on a full table | `scheduled-sixteen-smoke` |
| Kill a process from the shell | `kill <ep>`, `kill ep=<n>` | `debugger-kill-acceptance` |
| Kill a process from the debugger | `!kill <ep>` | `tui-soak` |
| Reuse the slot a kill freed | `run` after `kill` | `debugger-kill-acceptance` |
| Refuse to kill the shell | `kill 1` | `debugger-kill-acceptance`, `test-shell-command-parsing` |
| Stop an app from its pane | Escape | `tui-soak` |

## Typing at the shell

| Use case | Recipe |
| --- | --- |
| Correct a typo with backspace | `test-shell-command-parsing` |
| Leave an argument unfinished (`run x --`) without losing the prompt | `test-shell-command-parsing` |
| Old `--tty=new` spelling still accepted | `test-shell-command-parsing` |
| Reject a `kill` with no endpoint | `test-shell-command-parsing` |
| Answer commands with the table full | `tui-soak` |

## Watching the system

| Use case | How | Recipe |
| --- | --- | --- |
| Monitor processes as a program | `run mon` | `fill-demo-acceptance`, `tui-soak` |
| Several monitors at once | `run mon` twice | `debugger-kill-acceptance` |
| Always-present monitor pane | pane 4 | `tui-soak`, `windows-smoke` |
| List processes | `ps`, `ps -l` | `scheduled-stats-smoke` |
| Memory and slot totals | `mem` | `scheduled-memory-smoke` |
| Reclaim on exit | `mem` after children exit | `scheduled-reclaim-smoke` |

## The windowed frontend

| Use case | How | Recipe |
| --- | --- | --- |
| Focus a pane by number | `Ctrl-A 1`-`9` | `tui-soak` |
| Reach panes past nine | `Ctrl-A n` / `p` / `Tab` | `tui-soak` |
| Zoom, help, copy mode, broadcast | `Ctrl-A z ? y b,b` | `tui-soak`, `windows-smoke` |
| Close a pane and put it back | `Ctrl-A x`, `Ctrl-A S` | `tui-soak` |
| Clear a pane, keeping it open | `Ctrl-A l` | unit test |
| A reused pane starts empty | any relaunch on a freed slot | unit test |
| Save and restore a layout | `Ctrl-A w` / `R` | `windows-smoke` |
| Detach without killing the target | `Ctrl-A d` | `windows-smoke` |
| Survive a long interactive session | 118 interactions | `tui-soak` |
| Panes named after their process | any spawn | `tui-soak` |

## Scheduling under load

| Use case | Recipe |
| --- | --- |
| A program that never yields cannot starve the system | `preemption-acceptance` |
| Forced preemption keeps climbing under load | `fill-demo-acceptance` |
| Clocks keep running while hogs run | `fill-demo-acceptance` |
| Debugger answers while a hog runs | `preemption-acceptance` |
| Two children keep private state | `scheduled-multislot-smoke` |

## Debugging

| Use case | How | Recipe |
| --- | --- | --- |
| Registers of any endpoint | `regs <ep>` | `emulator-debugger-smoke` |
| Breakpoints, stepping, backtrace | `break` `step` `next` `bt` | `emulator-debugger-smoke` |
| Read memory | `x <addr>` | `emulator-debugger-smoke` |
| Run any shell command from the debugger | `!ps -l`, `!bg mon`, `!kill 3` | `tui-soak` |
| Memory map | `map hw|plan|live` | `debug-info-smoke` |
| Symbols and source | `sym`, `list`, `dis` | `debug-info-smoke` |

## Storage and devices

| Use case | Recipe |
| --- | --- |
| Load an app from SPI flash | `scheduled-spi-provider-smoke` |
| Load an app from SD | `scheduled-sd-provider-smoke` |
| Mixed resident and stored catalogs | `scheduled-composite-sd-mixed-smoke` |
| Concurrent loads from one device | `scheduled-concurrent-sd-smoke` |
| Read an I2C RTC | `i2c-ds1307-smoke` |

## Known gaps

No recipe covers these yet. They are real behaviours, not hypotheticals.

- **Startup commands.** Nothing runs `mon` for you when the frontend attaches;
  it has to be typed. The design is a catalog `autostart` flag acted on when
  the protocol enters framed mode, so the shell starts it once and reprints
  the menu.
- **The launcher's adapter watchdog.** `swtos-emulator-debug.py` now exits when
  the adapter dies, which was verified by hand but has no recipe.
- **Disassembly inside a spawned process.** `dis` and `list` refuse an address
  in a heap-loaded image copy, because the debug map covers only the linked
  image.
- **Transport-loss reporting.** The frontend's crash report and session log are
  not asserted anywhere.
- **Typed commands can be dropped by the frontend.** Several commands typed
  in quick succession sometimes reach the target as one: at the protocol level
  three consecutive `bg` commands all start, through te-rs sometimes only one
  does. The shell is not at fault; the loss is in the frontend's input path.
- **Arguments are still read character by character.** The command word is
  now a line and editable, but an argument -- the `-l` of `ps -l`, the name in
  `stat hello` -- is still matched as it arrives, so a typo there cannot be
  taken back.
- **No blocking launch.** Every launch returns to the prompt, so there is no
  way to say "run this and tell me when it is done". `run` and `bg` are
  synonyms; a waiting form would be a new `fg`.
