# What the output means

Every field the shell and the monitor print, and what it is measured in. The
labels are terse because they share a line with fifteen others on a 40-column
pane; this is the long form.

Two conventions run through all of it:

- **Words, not bytes**, wherever a field counts memory a process owns. A COR24
  word is three bytes. The `mem` summary is the exception and says `B`.
- **Endpoints are one-based.** Endpoint N lives in process-table slot N-1, and
  endpoint 1 is always the shell. `kill 3` and `kill ep=3` are the same line by
  the time anything acts on it.

## Process states

The number in `status=` and `s=`, and the word `ps` prints for it.

| Code | Word | Meaning |
|---|---|---|
| 0 | `FREE` | The slot holds no process. Everything else in the row is zero. |
| 1 | `RUNNABLE` | Ready to run, or running now. The scheduler will dispatch it. |
| 7 | `WAITING` | Parked in `TASK_GETCHAR` until something arrives on its own terminal: a keystroke for the shell, the next time frame for a clock. |
| other | `UNKNOWN` | Not a state this build assigns. Seeing one is a fault. |

`WAITING` is not an error. It is the ordinary state of a program with nothing
to do yet, which is why it is not called blocked.

## `ps`

One line per slot, all sixteen, whether or not anything is in them.

```
1 RUNNABLE
2 WAITING
3 FREE
```

The number is the endpoint. That is the whole line: `ps` answers "what slots
exist and are they in use", and nothing else.

## `ps -l` and `mon`

The same report from the same code. `ps -l` prints it once where it was typed;
`mon` clears its pane and prints it again on every clock tick, so its figures
are current and `ps -l` is a snapshot. Only live processes appear — a finished
one is absent rather than shown as a row of zeroes.

The header:

```
stk 1920/1920B heap 42/42B kstk=24B fail=0 slots=3/16
```

| Field | Unit | Meaning |
|---|---|---|
| `stk A/BB` | bytes | Stack arena in use / its peak. Processes take their stacks from here. |
| `heap A/BB` | bytes | Loaded-image heap in use / its peak. Private program images live here. |
| `kstk=` | bytes | High-water mark of the kernel's own stack, measured at boot by scanning for the first word boot changed. |
| `fail=` | count | Allocations refused since the last `mem -r`. |
| `slots=N/16` | count | Process-table slots in use. |

Both arenas are bump allocators: memory is reclaimed only when the last child
exits, so `in use` can sit above what is live.

Then one line per process:

```
uptime   ep=2 s=7 b=1 alloc=192/4w d=1 y=1 fp=0 cpu=0 ipc=0 io=0/7
```

| Field | Unit | Meaning |
|---|---|---|
| name | | The program in the slot, eight characters. |
| `ep=` | | Endpoint. |
| `s=` | code | Process state, from the table above. |
| `b=` | flag | Whether it is parked on its terminal. Redundant with `s=7` and kept because it is one character. |
| `alloc=A/Bw` | words | Stack words / process-local state words. The `w` marks the unit for both. |
| `d=` | count | Dispatches: how many times the scheduler has given it the CPU. |
| `y=` | count | Yields: how many times it gave the CPU back cooperatively. |
| `fp=` | count | Forced preemptions: how many times the interrupt handler took the CPU away. Only a `preemptible_leaf` image can be forced, so this stays zero for everything else. |
| `cpu=` | raw | The last interrupted-r0 sample — whatever was in r0 when it was last forcibly preempted. A hostile-loop progress counter, not a time. Zero unless `fp=` is climbing. |
| `ipc=` | count | Inter-process operations, which for these programs means spawns. |
| `io=A/B` | bytes | Terminal bytes in / out. |

`d` and `y` track each other closely for a cooperative program: it is
dispatched, it yields, and that is one of each.

## `mem`

```
total=1048576 image=9453 arena=256 peak=448 kstack=8 free=1038859 failures=0 slots=1/16
```

| Field | Unit | Meaning |
|---|---|---|
| `total=` | bytes | Installed SRAM. |
| `image=` | bytes | The linked SWTOS image: kernel, protocol and every resident program. |
| `arena=` | bytes | Stack arena in use. |
| `peak=` | bytes | The most the arena has ever held. |
| `kstack=` | bytes | Kernel stack high-water mark. |
| `free=` | bytes | What is left: total minus image, arena and kernel stack. |
| `failures=` | count | Allocations refused. |
| `slots=N/16` | count | Process-table slots in use. |

`mem -r` resets the counters that can safely restart while the shell runs. The
boot-time kernel stack watermark is deliberately kept, because it cannot be
measured again without rebooting.

## `mem -p`

One line per live process. Free slots are omitted; `ps` is where slots are
listed.

```
ep=1 status=1 stack=256@0FFD00 state=6@00715E image=resident total=262
ep=3 status=1 stack=128@0FF880 state=0@00717C image=3@00717C total=128
```

Each region is written `words@address`, and the address is hexadecimal so it
can be typed straight into `x` or `dis` in the debugger.

| Field | Meaning |
|---|---|
| `status=` | Process state code. |
| `stack=W@A` | W words of stack, starting at A. A is the **low** end of the allocation: a stack grows down from its high end, and reporting that end would say where it finishes rather than where it starts. |
| `state=W@A` | W words of process-local state at A. This is the block a program's `STATE_PTR` points at. Zero words is normal — `cpu-hog` keeps nothing. |
| `image=` | `resident` for a program that runs from the linked image, which every process shares and none of them owns. Otherwise `W@A`: the **live** extent of a private copy, which is the part the preemption runway manages, not the whole loaded image. |
| `total=` | Stack plus state, in words. It does not include the image. |

The arena allocates downward, so consecutive processes abut: one process's
stack address is the address just past the end of the next one's.

## `stat NAME` and `stat EP`

Describes a catalog entry rather than a running process.

| Field | Meaning |
|---|---|
| `kind=` | `program` or `service`. A service is started on the system's behalf; the monitor is one. |
| `source=` | `resident` (in the linked image) or `embedded` (loaded into the heap from a manifest). |
| `stack=` | Stack words the descriptor asks for at spawn. |
| `state=` | Process-local state words it asks for. |
| `flags=` | The descriptor's flag word. Bits: 1 resident, 2 single instance, 4 privileged, 8 autostart, 16 restartable, 32 read-only, 64 preemptible leaf. |
| `image=` | Bytes of image, for an embedded program. |

## `kill`

| Reply | Meaning |
|---|---|
| `READY` | Accepted. For endpoint 1 that means the shell is being rewound, not removed. |
| `nothing is running there` | The endpoint is a real slot and it is free. |
| `no such endpoint` | Outside the sixteen. |
| `kill needs an endpoint...` | No number was given. |

Accepted is not the same as finished: a `preemptible_leaf` image is torn down
by the interrupt handler at its next quiescent point, which is the next tick.
Everything else is released immediately.

## Where this is checked

`tests/test-scheduled-memory.sh`, `tests/test-scheduled-stats.sh` and
`tests/test-debugger-kill-acceptance.py` pin these formats. A field that
changes shape without one of them failing is a field nothing was reading.
