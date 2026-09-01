# Preemptive multitasking

## Purpose and acceptance criterion

SWTOS combines immediate cooperative switches at kernel boundaries with
UART-clock-enforced preemption. The definitive acceptance workload is
`cpu-hog`, whose complete loop increments `r0` forever and contains no yield,
syscall, UART access, TTY read, IPC, sleep, blocking operation, or mutable
memory access. While it runs, SWTOS must continue to service Resources and
Debugger requests, its forced-preemption count must advance, and successive
interrupted `r0` samples must differ.

The acceptance workload is intentionally expressed directly in COR24
assembly. A superficially equivalent PL/SW procedure would be:

```text
CPU_HOG: PROC;
    DCL COUNTER INT;
    COUNTER = 0;
    DO WHILE (1);
        COUNTER = COUNTER + 1;
    END;
END;
```

That form is not used for the definitive test because compiler-generated
loads, stores, prologue code, or runtime calls would weaken the claim being
tested. The complete tracked image source is
`catalog/images/cpu-hog.s`:

```asm
; Position-independent hostile task: no yield, syscall, memory access, IPC,
; sleep, blocking operation, or UART output.
_start:
        lc      r0,0
        lc      r1,1
_cpu_hog_loop:
        add     r0,r1
        bra     _cpu_hog_loop
```

Its manifest declares three text words and no data or BSS. Thus `r0` itself is
the counter sampled by Resources, and a changing `cpu=` value proves that the
same saved context was resumed and executed again after forced preemption.

The dual-hog demonstration launches this exact image twice. There is no second
or instrumented implementation: endpoint 2 and endpoint 3 receive independent
private live images, shadows, stacks, ISR frames, and `r0` counters containing
the assembly above. Catalog flag `preemptible_leaf` permits multiple certified
instances; `single_instance` is intentionally absent. Unequal saved `r0`
values and independent forced-preemption counts therefore demonstrate two real
resumable contexts.

Run the emulator proof with:

```sh
just preemption-acceptance
```

The lower-level ISA proofs are:

```sh
just interrupt-context-capability-smoke
just preemption-runway-smoke
```

## Scheduling policy

The normal path remains deliberately inexpensive. A task that yields, blocks
in `send`, `receive`, `sendrec`, TTY input, or sleep, or otherwise enters a
normal scheduling point switches through the existing cooperative context
format immediately.

The host supplies a 100 Hz clock. A dispatched process receives a five-tick
(50 ms) quantum. At expiry SWTOS marks preemption pending, giving the process
one additional heartbeat, or approximately 10 ms, to reach a normal scheduling
point. If the same private loaded process is still running at that heartbeat,
the kernel forcibly recovers it. Dispatch resets the quantum and pending flag.
Thus cooperation is an optimization, not a correctness requirement.

Resident kernel/PL/SW tasks currently retain the cooperative path. Forced
recovery is enabled for private C24IMG processes whose executable allocation
has the required landing and shadow storage. This confines self-modification
to private writable images and avoids carpeting shared resident text.

## UART clock

COR24-TB has no separate interval-timer peripheral. The Windows frontend sends
this fixed, unescaped sequence every 10 ms after framed negotiation:

```text
FF 01 tick-low tick-middle tick-high
```

The 24-bit value is absolute centiseconds, so elapsed time can be recovered
after host jitter rather than assuming every delivered interrupt represents
exactly one tick. Every byte arrives through the real COR24 UART interrupt on
both the FPGA and emulator.

The ISR recognizes scheduler heartbeats before placing ordinary traffic in its
bounded receive ring. The scheduled kernel drains that ring into the existing
framed protocol and recovery TTY paths. In unframed recovery mode, the same
timestamp is also forwarded to Uptime only when Uptime is the foreground
descriptor; it is never injected as binary Shell input. Typed Uptime and Clock
frames are likewise accepted only when the matching application is foreground.

The emulator debugger adapter normally transports complete SWT frames over its
PTY. It additionally recognizes the out-of-band five-byte heartbeat and injects
it directly into the modeled UART, making the Windows emulator demo exercise
the same interrupt bytes as physical hardware. The test-only transport kind
`FE` provides deterministic direct injection for the hostile acceptance test.

## COR24 interrupt constraint

On interrupt entry COR24 preserves the continuation PC in `r7`, named `ir`, and
the condition state in `c`. Software can return with `jmp (ir)`, but normal
instructions cannot copy `ir` into a general register or memory. A cooperative
switch therefore cannot directly save an arbitrary interrupted PC.

COR24 does provide the complementary resume primitive. Opcode `C7`, encoded as
`la` with destination field `r7`, is an absolute 24-bit immediate jump. It
changes PC without consuming or modifying `r0`, `r1`, `r2`, `fp`, `sp`, or the
condition state. SWTOS patches the three immediate bytes of one shared C7 stub
before restoring a task's complete state.

## Private process memory layout

The loader reserves this reclaimable layout for each eligible private image:

```text
+----------------------+----------------+----------------------+
| live text/data/BSS   | landing slot   | live-size shadow     |
+----------------------+----------------+----------------------+
       N words              2 words             N words
```

The two-word landing allocation is word-aligned and has room for the four-byte
C7 jump used during recovery. Per-slot sidecars retain live base and size,
landing and shadow addresses, quantum and pending state, forced-preemption
count, eligibility, IRQ-context state, and the last interrupted `r0` sample.
The public 39-byte `PROC_DESC` ABI is unchanged.

The preservation rule is:

> Snapshot and restore every byte that the runway overwrites, unless that
> region is guaranteed immutable and can be reconstructed from the executable
> image. Mutable data should preferably live outside the runway region.

The current C24IMG layout places text, initialized data, and BSS contiguously.
Consequently SWTOS snapshots and restores the entire live region, including
inline metadata, constants, and any mutable runtime bytes. A future split
text/data layout can reduce the copied region, but only after its immutability
and reconstruction rules are explicit.

## Forced interrupt recovery

The UART ISR first pushes interrupted `r0`, `r1`, `r2`, `fp`, and `c` on the
task stack. On the forced path it masks further UART interrupts and records the
stack pointer in the current descriptor. It then:

1. Copies every byte of the live region to its private shadow.
2. Writes a C7 absolute jump to the process's landing slot, targeting the
   common landing handler.
3. Replaces every live byte with opcode `01`, the one-byte `add r0,r1`.
4. Sets `r0` to the landing address and `r1` to `-1`.
5. Executes `jmp (ir)`.

If the interrupted continuation is `P` and the landing address is `E`, the
runway executes `E - P` additions. Starting with `r0 = E` and adding `-1`
therefore leaves `r0 = P` exactly when execution reaches the landing slot. No
alignment estimate or reserved application register is required.

The landing handler records that exact PC, samples interrupted `r0` from the
saved ISR frame, restores every live byte from the shadow, increments the
forced-preemption counter, marks the saved context as interrupt-originated,
and enters the ordinary runnable-process scan.

## Resuming an interrupt-originated context

When the scheduler selects such a process, it patches the shared C7 resume
stub with the saved PC before installing the process stack. With UART
interrupts still masked, it then restores `c`, `fp`, `r2`, `r1`, and `r0` from
the ISR frame and falls directly into the patched absolute jump. The final jump
has no general-register operand, so all visible interrupted state is intact at
the first not-yet-executed application instruction. UART interrupts are
enabled immediately before the register pops; the single-core machine and
interrupt-in-service state prevent another task from racing the shared stub.

## Resource monitoring

Resource snapshot record kind 6 carries an endpoint, a 24-bit forced-preemption
count, and a 24-bit interrupted-`r0` sample. The Resources pane renders these
as `fp=` and `cpu=`. `fp` is an event count, while `cpu` is an intentionally
simple progress witness for `cpu-hog`; neither is a percentage utilization
measurement. Zoom Resources or use horizontal copy-mode scrolling to see the
complete row in a narrow tiled layout.

## Tests and demo

`preemption-runway-smoke` proves exact PC recovery and C7 resume against a real
emulated UART IRQ. `preemption-acceptance` launches two background copies of
`cpu-hog`, sends clock heartbeats, and takes two complete resource snapshots.
Both endpoints must independently advance `fp` and `cpu`; coherent saved `r0`
samples must also change after resumption and another preemption. The test then
queues debugger termination for endpoint 2 and proves a later complete
Resources generation omits endpoint 2 while endpoint 3 remains live.
The Windows PTY test verifies parsing and rendering of kind 6 records. The full
gate is:

```sh
just emulator-acceptance
```

The tracked Windows tape launches Uptime and Clock, exercises symbolic and raw
debugger output, starts `cpu-hog`, zooms Resources to show forced activity,
queries registers twice, kills the parked hog, and shows its removal:

```sh
just windows-demo-record
```

The dedicated tape first displays the complete `catalog/images/cpu-hog.s`
source shown above. It then opens six panes, runs Uptime and Clock together to
show ordinary blocking workloads, stops both through their TTYs, and reuses
their endpoints and panes for two copies of that same hostile image. It shows
both hog names and zero-yield scheduler state with `ps -l`, reads `regs 2` and
`regs 3` twice, kills endpoint
2 only, and proves endpoint 3 remains live:

```sh
just preemption-demo-record
```

The sources are `docs/demos/cor24-preemption.tape` and the exact hog assembly
above; the encoded README asset is `videos/cor24-preemption-demo.webm`. The
tape's TTY Escape shutdown is intentional: Debugger `kill` targets a process
parked by forced preemption, whereas Uptime and Clock are normally blocked and
exit cleanly through their application TTY.

`scripts/with-demo-tools.sh` makes this recording reproducible on non-login
shells by resolving the conventional Go, Cargo, user-local, and system binary
paths. `just windows-demo-tools` prints the exact VHS, Cargo, and FFmpeg tools
and versions used.

## Limits and failure containment

- Shell `reboot` and frontend `Ctrl-A B` provide a warm recovery boundary.
  The ISR escape `FF 05` wakes endpoint 1 and defers cleanup until its next
  safe kernel entry; cleanup clears every child record, including runway
  sidecars and TTY rings, before rewinding the shell. It cannot recover a CPU
  that no longer accepts UART interrupts or reaches scheduler-safe code.
- Private allocation alone is insufficient. Catalog flag `preemptible_leaf`
  certifies a private image with zero relocations and no external control
  transfers; the generator rejects invalid combinations. Currently only the
  hostile `cpu-hog` carries it. Other images use blocking/yield scheduling
  until private syscall transition veneers are implemented.
- After runway landing, `current_proc` still names the interrupted owner while
  shared scheduler/protocol code executes. Sidecar `interrupt-context=1` is
  the authoritative quiescence marker: the clock cannot force it again, while
  debugger kill may queue termination for it. Reclamation occurs through
  `TASK_EXIT` after a later forced landing, never in the request handler.
- `regs EP` reads that parked ISR frame and saved PC; it does not itself
  preempt the target. Changed `r0` readings separated by heartbeats therefore
  prove that the same context resumed, ran, and was preempted again.
- Interrupts remain masked while executable bytes and the shared resume jump
  are transiently modified.
- The shadow doubles live-image storage, plus two landing words. Allocation
  failure follows the existing transactional spawn rollback path.
- The design is single-core. A multicore implementation would require private
  resume stubs or synchronization around code patching.
- The hardware acceptance test must confirm FPGA C7 behavior, UART IRQ entry,
  Resources progress, and Debugger response with `cpu-hog` running. Emulator
  success is necessary but does not replace that board validation.
