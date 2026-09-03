# Use cases and the proofs that hold them

What a person does with SWTOS, and which acceptance recipe fails if it stops
working. Every recipe here runs in `just emulator-acceptance`; a use case with
no recipe is listed as a gap rather than left implied.

Run one with `just <recipe>`.

## Starting and stopping programs

| Use case | How | Recipe |
| --- | --- | --- |
| See what programs exist | `ls`, `stat <name>`, `df`, `du` | `scheduled-catalog-smoke` |
| Run a program in its own pane | `run <name>`, `bg <name>`, or just `<name>` | `debugger-kill-acceptance`, `test-shell-command-parsing` |
| Start a program without blocking the prompt | `bg <name>` (same as `run`) | `test-shell-command-parsing`, `catalog-run-smoke` |
| Launch from the menu | keys `1`-`5`, `9` | `scheduled-shell-smoke` |
| Fill every process slot | menu `9` | `fill-demo-acceptance`, `scheduled-sixteen-smoke` |
| Run a program with no free slot | `run`/`bg` on a full table falls back to the shell's own context | `shell-sync-run` |
| Run a program here on purpose | `sync <name>` | `shell-sync-run` |
| Refuse to run an embedded program without a slot | `sync cpu-hog` | `shell-sync-run` |
| Kill a process from the shell | `kill <ep>`, `kill ep=<n>` | `debugger-kill-acceptance` |
| Kill a process from the debugger | `!kill <ep>` | `tui-soak` |
| Reuse the slot a kill freed | `run` after `kill` | `debugger-kill-acceptance` |
| Refuse to kill the shell | `kill 1` | `debugger-kill-acceptance`, `test-shell-command-parsing` |
| Stop an app from its pane | Escape | `tui-soak` |

## Typing at the shell

| Use case | Recipe |
| --- | --- |
| Correct a typo anywhere in a line | `test-shell-command-parsing` |
| Explain one command | `help bg`, `help kill` | `test-shell-command-parsing` |
| Leave an argument unfinished (`run x --`) without losing the prompt | `test-shell-command-parsing` |
| Old `--tty=new` spelling still accepted | `test-shell-command-parsing` |
| Reject a `kill` with no endpoint | `test-shell-command-parsing` |
| Answer commands with the table full | `tui-soak` |

## Watching the system

| Use case | How | Recipe |
| --- | --- | --- |
| Monitor processes | `mon`, started at boot | `fill-demo-acceptance`, `tui-soak` |
| Several monitors at once | `run mon` twice | `debugger-kill-acceptance` |
| See which slots are taken | `ps`: RUNNABLE, WAITING (for input on its own terminal), FREE | `scheduled-stats-smoke` |
| See what is running, in detail | `ps -l` (same report as `mon`) | `scheduled-stats-smoke` |
| Memory and slot totals | `mem` | `scheduled-memory-smoke` |
| Reclaim on exit | `mem` after children exit | `scheduled-reclaim-smoke` |

## The windowed frontend

| Use case | How | Recipe |
| --- | --- | --- |
| Focus a pane by number | `Ctrl-O 1`-`9` | `tui-soak` |
| Reach panes past nine | `Ctrl-O n` / `p` / `Tab` | `tui-soak` |
| Zoom, help, copy mode, broadcast | `Ctrl-O z ? y b,b` | `tui-soak`, `windows-smoke` |
| Close a pane and put it back | `Ctrl-O x`, `Ctrl-O S` | `tui-soak` |
| Clear a pane, keeping it open | `Ctrl-O l` | unit test |
| See that a pane's process has ended | `(ended)` in its name, including a program too short-lived for any snapshot to catch | `tui-soak`, unit test |
| Reclaim the space of finished programs | `Ctrl-O c` | `tui-soak`, unit test |
| Kill a process in a slot that once held another | any `kill`, after the slot has been reused | `debugger-kill-acceptance` |
| See where a process's memory is, not just how much | `mem -p` | `scheduled-memory-smoke` |
| Get back a shell that has stopped responding | `Ctrl-O k`, debugger `!kill 1`, or `kill 1` at a working prompt | `shell-restart`, `debugger-kill-acceptance` |
| Return a responsive kernel to a clean process baseline | shell `reboot` or `Ctrl-O B` ISR request | `shell-command-parsing`, `windows-smoke` |
| Keep the keyboard at the prompt when a program starts or exits | any `bg`, and any child exiting while the monitor runs | `shell-foreground` |
| A reused pane starts empty | any relaunch on a freed slot | unit test |
| Save and restore a layout | `Ctrl-O w` / `R` | `windows-smoke` |
| Detach without killing the target | `Ctrl-O d` | `windows-smoke` |
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
| Symbols and source | `sym`, `list` | `debug-info-smoke` |
| Disassemble anywhere, map or not | `dis <addr>` | unit test against the linker's own output |

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

- **A synchronous program that is silent, deaf and never yields.** The restart
  escape is raised by the UART interrupt handler but acted on by the kernel at
  its next entry from the shell, because COR24 cannot load an interrupted PC.
  A program that never reads, writes or yields reaches none of those entries.
  That is the same limit every process on this target has, and lifting it needs
  the ISA to make `ir` readable and writable.
- **The launcher's adapter watchdog.** `swtos-emulator-debug.py` now exits when
  the adapter dies, which was verified by hand but has no recipe.
- **Source lines inside a spawned process.** `dis` now decodes any address by
  reading the bytes, but `list` still needs the map, so a spawned copy shows
  instructions without the source they came from. Mapping a copy back to its
  origin image would need the loader to report each process's load base.
- **Live disassembly reads twelve bytes at a time**, which is the debug
  protocol's memory-read size: three long instructions or a dozen short ones.
  A longer listing means several reads and somewhere to keep them.
- **Transport-loss reporting.** The frontend's crash report and session log are
  not asserted anywhere.
- **Typed commands can be dropped by the frontend.** Several commands typed
  in quick succession sometimes reach the target as one: at the protocol level
  three consecutive `bg` commands all start, through te-rs sometimes only one
  does. The shell is not at fault; the loss is in the frontend's input path.
- **No blocking launch.** Every launch returns to the prompt, so there is no
  way to say "run this and tell me when it is done". `run` and `bg` are
  synonyms; a waiting form would be a new `fg`.
