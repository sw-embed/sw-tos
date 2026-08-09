# SWTOS -- Software Wrighter Tiny Operating System

*A portable microkernel for educational and embedded systems.*

---

## 1. Design Philosophy

SWTOS is a clean-room microkernel operating system inspired by MINIX IPC
principles but designed natively for small CPUs and FPGA soft cores. It is
not a MINIX port; it is a new system.

### Goals

| Goal             | Description                                                   |
|------------------|---------------------------------------------------------------|
| Tiny             | Fits comfortably on small FPGA CPUs with limited RAM          |
| Portable         | Only the HAL depends on the target ISA                       |
| Deterministic    | Everything is understandable and predictable                  |
| Educational      | Easy to read, modify, and experiment with                     |
| Cooperative-first| Preemption is optional, not required                           |
| Message-passing  | All inter-process communication through synchronous messages  |
| No dynamic deps  | Entire system compiles into one flat binary                   |
| Resident apps    | Programs are cataloged at build time, not loaded from files   |
| Modular services | Service tasks are replaceable at runtime                      |
| Emulator-first   | Runs identically on hardware and in a software emulator       |

### What SWTOS Is Not

- Not a POSIX or UNIX-compatible system
- Not a MINIX port (MINIX concepts are used as architectural reference only)
- No network stack (host communication is over the UART transport only)
- No conventional filesystem (replaced by a resident object catalog)
- No MMU required (single address space with logical process isolation)
- No floating point required
- No hardware multiply required (compiler runtime provides `__mul24` etc.)
- No hardware timer required (clock comes from UART-hosted virtual timer)

---

## 2. Target Hardware

Primary target: **COR24-TB** FPGA development board

- **CPU**: MakerLisp COR24 soft CPU (Verilog, Lattice MachXO FPGA)
- **Clock**: 101.7 MHz (33.9 MHz oscillator x 3 PLL)
- **RAM**: 1 MB SRAM (ISSI IS61WV10248EDBLL)
- **Console**: UART at 921,600 baud (external USB/UART bridge)
- **I/O**: 10 GPIO pins, 1 LED, 1 pushbutton, reset button
- **Buses**: I2C (header J2), SPI (header J3)
- **FPGA**: Lattice LCMXO2280C-5TN144C
- **Programming**: JTAG via Lattice HW-USBN-2B

---

## 3. System Architecture

```
+-----------------------------------+
| Applications                      |  hello, ps, ipc-demo, counter, ...
+-----------------------------------+
| Resident Services                 |
|   shell                           |
|   tty                             |
+-----------------------------------+
| SWTOS Microkernel                 |
|   process table & scheduler       |
|   IPC (send / receive / sendrec)  |
|   sleep queue                     |
|   kernel heap & stack allocator   |
|   UART-hosted virtual timer       |
+-----------------------------------+
| COR24 HAL (Hardware Abstraction)  |
|   UART, GPIO, SPI, I2C access    |
|   context save/restore            |
|   interrupt entry/exit            |
|   boot trampoline                 |
+-----------------------------------+
```

### Key Architectural Decisions

1. **Resident object catalog instead of filesystem.** Programs and data blobs
   are indexed in a build-time generated table. `run hello` looks up the
   entry point and spawns a new process -- no loader, no file format, no disk.
2. **UART-hosted virtual timer.** The host terminal sends periodic heartbeat
   frames over UART, providing preemptive scheduling without a hardware timer.
   Falls back to cooperative scheduling when no heartbeat is present.
3. **Shared text, private context.** All resident programs share the same code
   region. Each process gets its own stack, saved registers, and an optional
   per-process state block allocated from the heap.
4. **Purpose-specific services, not POSIX syscalls.** Instead of `open/read/write`,
   services expose typed messages: `TTY_WRITE`, `TTY_READ_LINE`, `PROGRAM_LIST`,
   `PROGRAM_SPAWN`, `PROCESS_LIST`, `PROCESS_KILL`, `CLOCK_SLEEP`.
5. **Kernel owns process table and scheduler directly.** No separate process
   manager task in v1. Keep the initial service set to just `tty` and `shell`.

---

## 4. COR24 PL/SW Data Model

PL/SW targets the COR24 24-bit RISC ISA directly. Types:

| PL/SW Type     | COR24 Representation           |
|----------------|----------------------------------|
| `INT(24)`      | 24 bits (native word)            |
| `INT(16)`      | 24 bits (stored in full word)    |
| `INT(8)`       | 24 bits (stored in full word)    |
| `BYTE`         | 24 bits (one character per word)  |
| `CHAR`         | 24 bits (one character per word)  |
| `PTR`          | 24 bits                          |
| `WORD`         | 24 bits (raw address)            |
| `BIT`          | 24 bits (0 or 1)                 |

PL/SW does not support floating point. `FLOAT` and `DOUBLE` are not
available. This matches SWTOS requirements exactly.

One character per 24-bit word wastes memory but keeps the compiler, pointer
arithmetic, UART driver, shell, and data handling simple. Optimize packing
later if needed.

### PL/SW Inline Assembly for HAL

PL/SW supports `ASM DO` blocks and `NAKED` procedures for
hardware-specific operations that cannot be expressed in the high-level
language. All HAL code (context switch, interrupt entry/exit, UART
register access) uses this facility.

### Compiler Runtime Helpers (no hardware multiply)

```c
DCL __MUL24  ENTRY(INT(24), INT(24)) RETURNS(INT(24));
DCL __UMUL24 ENTRY(INT(24), INT(24)) RETURNS(INT(24));
DCL __DIV24  ENTRY(INT(24), INT(24)) RETURNS(INT(24));
DCL __UDIV24 ENTRY(INT(24), INT(24)) RETURNS(INT(24));
DCL __MOD24  ENTRY(INT(24), INT(24)) RETURNS(INT(24));
DCL __UMOD24 ENTRY(INT(24), INT(24)) RETURNS(INT(24));
```

The PL/SW compiler emits calls to these when the COR24 ISA lacks native
multiply/divide instructions.

---

## 5. Memory Map (1 MB SRAM)

```
LOW MEMORY
+--------------------------+
| reset vectors            |
| interrupt entry          |
| kernel text              |
| kernel constants         |
| resident program text    |
| string/data blobs        |
| object catalog           |
+--------------------------+
| kernel mutable data      |
| process table            |
| IPC message pool         |
| UART buffers             |
| heap / state allocator   |
| process stacks           |
+--------------------------+
HIGH MEMORY
```

Approximate allocation:

| Region                               | Size       |
|--------------------------------------|------------|
| Kernel + resident code (read-only)   | 256K words |
| Read-only data + catalog             | 128K words |
| Kernel structures + buffers          | 128K words |
| Stacks + per-process state           | 512K words |

All regions are fixed-address initially. No MMU, no virtual addresses.
Logical isolation is enforced by convention: separate stacks, separate
process descriptors, no shared writable globals between services,
pointer validation on syscalls where practical.

---

## 6. Kernel Subsystems

### 6.1 Process Model

Static process table (max ~16 processes). Each entry:

```c
struct proc {
    cor_word_t    regs[COR_NREGS];
    cor_addr_t    sp;
    cor_addr_t    pc;
    cor_word_t    status;

    endpoint_t    endpoint;
    endpoint_t    sender;
    endpoint_t    receiver;

    cor_word_t    state;
    cor_word_t    priority;
    cor_word_t    quantum_remaining;

    struct message *pending_msg;
};
```

Process states: `RUNNABLE`, `READY`, `RECV_BLOCKED`, `SEND_BLOCKED`,
`SLEEPING`, `ZOMBIE`.

### 6.2 Scheduler

- Cooperative round-robin via explicit `yield()` syscall (always available)
- Preemptive round-robin when UART heartbeat clock is active
- Quantum: 2 ticks (20 ms at 100 Hz) or 5 ticks (50 ms) for less responsive
  but more efficient scheduling
- No priority scheduling in v1

### 6.3 IPC -- Synchronous Message Passing

```c
int send(endpoint_t destination, struct message *m);
int receive(endpoint_t source, struct message *m);
int sendrec(endpoint_t destination, struct message *m);
```

Fixed-size messages:

```c
#define ANY  ((endpoint_t)-1)

struct message {
    endpoint_t  source;
    cor_word_t  type;
    cor_word_t  value[6];
};
```

A process blocks if the peer is not ready. The kernel copies messages
between process descriptors -- no shared memory between processes.

### 6.4 Sleep Queue

Processes can sleep for a number of ticks:

```c
int sleep_ticks(unsigned ticks);
```

The UART heartbeat ISR updates the monotonic tick counter. Before returning
from interrupt, the kernel scans the sleep queue and marks expired sleepers
as `READY`.

### 6.5 System Call Interface

User processes invoke the kernel via a software trap:

```
Register 0:  system call number
Register 1-5: arguments
Return:      Register 0
```

| Syscall          | Purpose                              |
|------------------|--------------------------------------|
| `SYS_YIELD`      | Voluntarily relinquish CPU            |
| `SYS_EXIT`       | Terminate calling process            |
| `SYS_SEND`       | Send a message to an endpoint        |
| `SYS_RECEIVE`    | Receive a message from an endpoint   |
| `SYS_SENDREC`    | Combined send + receive              |
| `SYS_SLEEP`      | Sleep for N ticks                    |
| `SYS_GETPID`     | Get caller's endpoint ID             |
| `SYS_KILL`       | Terminate another process            |
| `SYS_SPAWN`      | Spawn a resident program             |
| `SYS_CLOCK`      | Get monotonic tick count             |

---

## 7. UART-Hosted Virtual Timer

COR24 may lack a hardware timer. SWTOS solves this with a
**UART-hosted virtual timer**: the host terminal sends periodic
timestamped heartbeat frames over UART.

### Transport Protocol

Three-layer design:

```
Layer 3: TTY service (line editing, canonical input)
Layer 2: COR24 serial transport (escape framing, control frames)
Layer 1: UART hardware (raw bytes, RX interrupt)
```

#### Escape Framing

```
0xFF 0x00          literal 0xFF data byte (escaped)
0xFF 0x01 T0 T1 T2  heartbeat frame (24-bit host tick)
0xFF 0x02 ...      future control packet (reserved)
All other bytes    pass through as ordinary data
```

Heartbeats use a 24-bit wrapping counter (natural for COR24).
The kernel computes elapsed ticks as `delta = current - previous`,
handling wraparound and missed heartbeats gracefully.

Heartbeat rate: **100 Hz** (10 ms per tick). At 921,600 baud, a 5-byte
heartbeat frame costs 300 bytes/second -- negligible bandwidth (~0.3%).

#### ISR Behavior

The UART ISR remains minimal:

1. Read UART byte
2. Run tiny framing state machine (3 states: NORMAL, ESCAPE, HEARTBEAT)
3. Ordinary data: enqueue in RX ring buffer
4. Completed heartbeat: update monotonic tick counter, set reschedule flag
5. Return from interrupt

The ISR must NOT do calendar conversion, process-table scans, line editing,
or filesystem work.

#### Scheduler Integration

On heartbeat:

```c
void clock_receive_heartbeat(cor_word_t host_tick) {
    cor_word_t elapsed = host_tick - last_host_tick;
    last_host_tick = host_tick;
    monotonic_ticks += elapsed;
    wakeup_pending = 1;
    reschedule_pending = 1;
}
```

Before returning from interrupt to user code, the kernel enters the
scheduler. A non-yielding CPU-bound process can be preempted:

```c
for (;;) { compute(); }   /* gets preempted every 20-50 ms */
```

#### Bootstrap

1. Initialize UART in cooperative mode
2. Launch TTY and shell
3. Wait for first valid heartbeat frame
4. Mark clock synchronized
5. Enable scheduler quantum expiration

Without heartbeats (terminal disconnect), SWTOS falls back to cooperative
scheduling. Processes are expected to call syscalls or `yield()`.

#### Host Terminal Requirements

- Send heartbeats at fixed wall-clock intervals even during active input
- Use wrapping counter, not mere increment-by-one
- Use raw TTY mode, disable flow control and newline translation
- Set low-latency serial options where available
- Optionally negotiate heartbeat mode via control frame exchange

The emulator client is `scripts/swtos-terminal.py`, used by
`just plsw-system-interactive`. It starts one wall-clock timestamp heartbeat
per second when menu choice `3` launches the resident PL/SW Clock app. The
timestamp remains expressed in 100 Hz ticks, so delayed delivery still
preserves elapsed time. Ctrl-] is translated to the app's escape byte and
stops heartbeat generation before control returns to the menu.

---

## 8. Resident Object Catalog

Instead of a filesystem, SWTOS uses a **build-time generated catalog** of
resident programs and data blobs.

### Catalog Descriptor

```c
enum image_kind {
    IMAGE_PROGRAM,
    IMAGE_DATA,
    IMAGE_SERVICE,
};

enum image_flags {
    IMAGE_RESIDENT      = 0x01,
    IMAGE_SINGLE_INST   = 0x02,
    IMAGE_PRIVILEGED    = 0x04,
    IMAGE_AUTOSTART     = 0x08,
    IMAGE_RESTARTABLE   = 0x10,
    IMAGE_READ_ONLY     = 0x20,
};

struct image_descriptor {
    const char      *name;
    cor_word_t       kind;
    const cor_word_t *base;
    cor_word_t       words;
    cor_word_t       entry_offset;
    cor_word_t       stack_words;
    cor_word_t       state_words;
    cor_word_t       flags;
};
```

### Build Manifest (TOML)

```toml
[[program]]
name = "hello"
entry = "hello_main"
stack_words = 128
state_words = 0

[[program]]
name = "counter"
entry = "counter_main"
stack_words = 192
state_words = 1

[[program]]
name = "ipc-demo"
entry = "ipc_demo_main"
stack_words = 256
state_words = 8

[[service]]
name = "tty"
entry = "tty_main"
stack_words = 256
state_words = 32
flags = ["autostart", "privileged", "restartable"]
```

The build tool generates the descriptor table from this manifest.
No manual table maintenance.

The implemented manifest is `catalog/catalog.toml`; generation is handled by
`scripts/generate-catalog.py`. It validates the schema, names, linked entry
symbols, sizes, kinds, flags, and duplicates before emitting
`include/catalog_generated.msw`. PL/SW cannot take `ADDR()` of a procedure, so
the generated initializer uses PL/SW for descriptor data and a small inline
assembly block for linked entry addresses. `just catalog-smoke` checks that the
generated files are current and compiles the PL/SW table into the compatibility
image. The same generator emits `hal/cor24/catalog_generated.s`, whose
descriptors and name storage are appended to the scheduler kernel before
assembly and linking.
At boot, `CATALOG_AUTOSTART` scans the generated descriptor flags and invokes
each selected entry through `CATALOG_CALL_ENTRY`; `system.plsw` contains no
direct shell call. `CATALOG_FIND_PROGRAM` compares a requested name against
program descriptors and returns the linked entry for indirect dispatch.
`CATALOG_LIST` walks the same table and prints every program and service name.

### Program Spawning

The simplest v1 uses a direct entry-point table:

```c
struct resident_program {
    const char *name;
    void (*entry)(void *state_ptr);
    cor_word_t stack_words;
    cor_word_t state_words;
};
```

`run hello` does:

```c
descriptor = catalog_find("hello");
process_spawn(descriptor);  /* allocate stack + state, set PC */
```

No loader, no relocations, no executable format. Programs share
resident text but each instance gets its own stack and state block.

Application code avoids writable globals; instead, all mutable state is
passed via the per-process state pointer:

```c
void counter_main(void *state_ptr) {
    struct counter_state *state = state_ptr;
    for (;;) {
        state->value++;
        tty_print_number(state->value);
        sleep_ticks(100);
    }
}
```

### Future: Embedded Executable Blobs

For dynamically loaded programs (from SPI flash, for example), the same
catalog interface is retained. The image descriptor includes `base`,
`text_words`, `data_words`, `bss_words`, and `entry_offset`. The loader
copies text/data, clears BSS, applies relocations, and sets PC.

The implemented version 1 on-storage header is nine COR24 words (27 bytes).
Every word is encoded most-significant byte first so host tooling is independent
of native integer layout:

| Word | Field | Meaning |
|------|-------|---------|
| 0-1 | magic | ASCII `C24IMG` |
| 2 | version | Format version, currently `1` |
| 3 | text words | Payload text length |
| 4 | data words | Payload initialized-data length |
| 5 | BSS words | Zero-filled words not stored in payload |
| 6 | entry offset | Word offset into text |
| 7 | relocation count | Must be zero in version 1 |
| 8 | checksum | Low 24 bits of payload CRC-32 |

Text words followed by data words form the packed three-byte-word payload.
`scripts/cor24-image.py` validates 24-bit ranges, exact payload length, entry
bounds, format version, relocation policy, and checksum. The first deterministic
manifest is `catalog/images/loader-smoke.toml`; `just cor24-image-smoke` builds
it and proves rejection of corrupt magic, payload, and length. This establishes
the provider-facing artifact but does not yet load or execute it.

Two image providers coexist:

```
resident provider  ->  direct memory reference
SPI provider       ->  block reads through SPI HAL
```

The shell does not care where the program resides.

### Future: Storage Providers

When SPI storage arrives, the same `image_provider` interface is used:

```c
struct image_provider {
    int (*find)(const char *name, struct image_descriptor *out);
    int (*read)(const image_descriptor *img, cor_word_t offset,
                cor_word_t *buf, cor_word_t words);
};
```

The catalog manager searches: (1) resident catalog, (2) SPI catalog.

---

## 9. Boot Sequence

1. COR24 CPU starts at address 0x000000
2. HAL boot trampoline:
   - Initialize UART (921,600 baud, polling mode)
   - Initialize stack pointer
   - Zero kernel BSS
3. Kernel initialization:
   - Set up interrupt vector table
   - Initialize process table (all slots FREE except kernel pseudo-process)
   - Initialize IPC message pool
   - Initialize heap / stack allocator
   - Initialize object catalog
4. Start AUTOSTART services (TTY)
5. Start shell
6. Print banner
7. Begin cooperative scheduling
8. On first heartbeat: mark clock synchronized, enable preemption

### Banner Example

```
SWTOS 0.1 (Software Wrighter Tiny Operating System)
COR24 soft CPU @ 101.7 MHz
1024K words physical memory
clock: cooperative (no heartbeat)
tty: polling UART @ 921600 baud
catalog: 8 resident objects
```

---

## 10. Shell

Minimal built-in shell with these commands:

| Command           | Action                                       |
|-------------------|----------------------------------------------|
| `help`            | Print available commands                     |
| `run <name>`      | Spawn a cataloged program                    |
| `ps`              | List processes and their states              |
| `kill <endpoint>` | Terminate a process                           |
| `sleep <ticks>`   | Sleep for N ticks                             |
| `uptime`          | Print monotonic tick count                   |
| `mem`             | Print memory usage                           |
| `ls`              | List cataloged objects                        |
| `echo <text>`     | Print text                                    |
| `clock`           | Print clock status (synced/cooperative)       |

No path parsing, no current directory, no file descriptors, no permissions.

---

## 11. Initial Process Set

### System Processes

| Endpoint | Name   | Role                        |
|----------|--------|-----------------------------|
| 0        | kernel | Pseudo-process (scheduler)  |
| 1        | idle   | Runs when nothing is ready  |
| 2        | tty    | UART/TTY service            |
| 3        | shell  | Command interpreter         |

### Resident Applications

| Name        | Purpose                                       |
|-------------|-----------------------------------------------|
| `hello`     | Print greeting and exit                       |
| `counter`   | Increment and print, sleeping between counts  |
| `ps`        | Print process table                           |
| `ipc-demo`  | Client/server message exchange                |
| `sleep-demo`| Demonstrate sleeping and wakeup              |
| `mem`       | Print heap/stack usage                        |
| `uptime`    | Print monotonic tick counter                  |

---

## 12. TTY Service

### Polled Mode (v1)

```c
void console_putc(int ch) {
    while (!uart_tx_ready()) { /* spin */ }
    uart_putc((unsigned)ch);
}

int console_getc(void) {
    while (!uart_rx_ready()) { /* spin */ }
    return (int)uart_getc();
}
```

### Interrupt-Driven Mode (v2)

- UART RX interrupt reads byte, runs framing state machine
- Ordinary data enqueued in 64-byte circular buffer
- Heartbeat frames update clock counter
- TTY task awakened on data arrival
- TTY task handles line editing (backspace, newline translation)
- Blocking reads complete when a full line is available
- Kernel retains direct UART output path for panic messages

### UART HAL Abstraction

```c
int  uart_rx_ready(void);
int  uart_tx_ready(void);
unsigned uart_getc(void);
void uart_putc(unsigned ch);
void uart_enable_rx_irq(void);
void uart_disable_rx_irq(void);
```

---

## 13. Service Restart (Reincarnation Manager)

Inspired by MINIX 3's fault-tolerant service architecture:

- Services flagged `IMAGE_RESTARTABLE` are monitored
- On service crash (exit), the kernel notifies the reincarnation manager
- Manager restarts the service, re-initializes its state block
- Logs the failure (to UART console)
- Later: preserve/restore state for stateful services (RAMFS, etc.)

This demonstrates one of MINIX's most distinctive features without porting
MINIX itself.

---

## 14. Source Tree Layout

```
swtos/
    kernel/
        proc.plsw       process table, spawn, exit
        sched.plsw      scheduler (cooperative + preemptive)
        ipc.plsw        send, receive, sendrec
        clock.plsw      heartbeat timer, sleep queue
        syscall.plsw    system call dispatch
        heap.plsw       kernel memory allocator
    hal/
        cor24/
            boot.s       reset vector, stack init
            interrupt.s  interrupt entry/exit
            context.s    save/restore registers, context switch
            uart.s       raw UART access
            gpio.s       GPIO access
    services/
        tty.plsw        TTY service (polled then interrupt-driven)
        shell.plsw      command interpreter
    catalog/
        catalog.plsw    find, list, spawn from catalog
        manifest.py     build tool: manifest -> descriptor table
    apps/
        hello.plsw
        counter.plsw
        ps.plsw
        ipc_demo.plsw
        sleep_demo.plsw
        mem.plsw
        uptime.plsw
    include/
        swtos.msw       master declarations
        kernel.msw
        proc.msw
        ipc.msw
        message.msw
        catalog.msw
        hal.msw
    lib/
        printf.plsw
        string.plsw
        memset.plsw
        memcpy.plsw
    build/
        Makefile
        link.ld         linker script (link24)
```

---

## 15. Development Milestones

### Milestone 0 -- PL/SW Systems Programming Readiness

Before building OS components, prove PL/SW can handle systems-level
constructs needed by SWTOS:

- [x] RECORD types for process descriptors and message structs
- [x] PTR dereference and field access for linked structures
- [x] ADDR() and SIZEOF() built-ins for layout-sensitive code
- [x] NAKED procedures and ASM DO blocks for HAL routines
- [x] Separate .plsw modules assembled and linked together (link24)
- [x] Global/static data initialization
- [x] %INCLUDE / %DEFINE / %IF for conditional compilation
- [x] Volatile memory-mapped I/O access (UART, LED registers)
- [x] MACRODEF/GEN for recurring kernel patterns

**Status:** smoke-test.plsw compiles and runs. Proven: BASED record
templates with PTR dereference, %INCLUDE with FILE: protocol, %DEFINE
constants, MACRODEF/GEN invocation, ADDR(), inline ASM via ASM DO,
DO WHILE loop, PROC with stack frame.

**Known PL/SW constraints discovered:**
- BASED records are templates, not named type specifiers. You cannot
  write `DCL M MESSAGE;` -- instead use `P = ADDR(LOCAL_BUF); P->FIELD`.
- Comments must be on their own lines. Trailing `/* ... */` after
  `%DEFINE X 42;` causes a syntax error.
- The `-u` (UART input string) flag has a bug with the FILE:/SOURCE:
  protocol -- characters are lost when `SOURCE:` prefix is present.
  Use `--uart-file` instead (see pipeline.sh).
- PL/SW compiler runs as a COR24 program on the emulator. Compile time
  is ~3 seconds for typical programs (not minutes -- the delay was
  caused by incorrect `--terminal --echo` usage instead of `--uart-file`).

**Deliverable:** `smoke-test.plsw` compiles and runs in the emulator.
`just plsw-link-smoke` independently compiles an entry module and library,
generates symbol/FIXUP metadata, performs two-pass assembly, links them with
link24, and verifies the linked program output in the emulator.

**Status:** Complete. Next: Milestone 1, linked tasks with cooperative context
switching.

### Milestone 1 -- Linked Tasks with Context Switch

- [x] Boot stub: initialize stack, poll UART, print banner
- [x] Static task table with 2 tasks
- [x] Separate task stacks in fixed EBR regions
- [x] Stack allocation from EBR bump allocator
- [x] Assembly context save/restore
- [x] Cooperative `yield()` round-robin
- [x] Polled UART output from tasks

**Demo:** Tasks alternate printing: `A: 1`, `B: 1`, `A: 2`, `B: 2`

**Status:** `just context-switch-smoke` fabricates initial contexts for two
tasks on disjoint EBR stacks, saves and restores `r0`, `r1`/PC, `r2`, and
`fp`, and verifies alternating output through three rounds. Stack regions are
assigned by a downward bump allocator rather than embedded task addresses.
The scheduler stores allocated SPs, initial PCs, endpoints, and runnable state
in records matching the PL/SW `PROC_DESC` ABI, and `yield` saves/restores via
the current descriptor pointer. The boot trampoline establishes the kernel
stack and prints `SWTOS M1` through the polling UART path before allocating
tasks.

**Status:** Complete. Next: Milestone 2, MINIX-style synchronous IPC.

### Milestone 2 -- MINIX-Style IPC

- [x] Callable `send()` and `receive()` kernel entries
- [x] `sendrec()` combined kernel entry with reply delivery
- [x] Fixed-size seven-word message struct and kernel copy
- [x] Blocking send/receive semantics with peer wakeup
- [x] TTY service task receiving `TTY_WRITE` messages

**Demo:** Client process sends a string to TTY service; TTY prints it.

**Status:** `just ipc-smoke` starts the TTY task first so it enters
`PROC_RECV_BLOCK`, then runs a client that enters `PROC_SEND_BLOCK` with a
seven-word `TTY_WRITE` message. The receiver copies all message words into a
private buffer, wakes the sender, emits the payload, and synchronously replies.
`send`, `receive`, and `sendrec` use the PL/SW stack calling convention and are
called normally by the demo tasks.

**Status:** Complete. Next: Milestone 3, UART heartbeat clock and sleep queue.

### Milestone 3 -- UART Heartbeat Clock

- [x] Escape framing in UART ISR
- [x] Escape framing state machine proven in polling mode
- [x] 24-bit heartbeat counter with wraparound
- [x] Monotonic tick counter in kernel
- [x] Sleep queue scan with absolute tick-based wakeup
- [ ] Preemptive scheduling from ISR (if COR24 supports context
  switch from interrupt return)
- [x] Cooperative fallback before the first heartbeat

**Demo:** CPU-bound process preempted; shell remains responsive.
Sleep command works.

**Status:** `just heartbeat-smoke` separates ordinary UART data, escaped
`0xFF`, and five-byte heartbeat frames, then verifies natural 24-bit delta
arithmetic across wraparound. The parser runs one byte per UART interrupt,
preserves registers and the condition flag, and returns through `ir`; a
foreground counter proves interrupted execution resumes. The same test scans
sleeping entries after the clock update and marks deadlines at or before the
monotonic tick runnable. `just plsw-system-interactive` now provides the
host-side clock source, and menu choice `3` runs a PL/SW Clock app that logs
`mm:ss` once per second until Ctrl-]. `just clock-smoke` verifies timestamps
from `00:00` through `00:02` and the return to the menu.

**Preemption feasibility result:** The current COR24 ISA/toolchain can return
from an interrupt with `jmp (ir)`, but cannot copy `ir` to or from a general
register (`mov r2,ir` and `mov ir,r2`) or memory (`sw ir` and `lw ir`). An ISR
can therefore preserve and resume its current interrupted PC, but cannot save
one task's interrupted PC and load another task's PC. Safe arbitrary-PC context
switching directly from interrupt return is blocked unless COR24 gains an
instruction for reading and writing `ir`, or the interrupt ABI is extended to
save the interrupted PC in software-visible memory. SWTOS remains
cooperative-first on the current target.

**Cooperative fallback:** `just cooperative-fallback-smoke` starts with no
UART heartbeat input and reports `C0` (clock unsynchronized), then completes
the cooperative two-task context-switch and blocking IPC sequence. This makes
the boot-time fallback explicit: scheduler progress does not depend on clock
synchronization. Once synchronized, total heartbeat loss cannot be detected
from elapsed time because COR24 has no independent timer; the system continues
cooperatively whenever tasks enter the kernel or call `yield`, but cannot
declare the host clock stale by itself.

**Status:** Complete for the current COR24 interrupt ABI: heartbeat framing,
monotonic time, sleep wakeups, host clock generation, a resident Clock app,
and pre-synchronization cooperative fallback are proven. Interrupt-time
preemption remains an explicitly documented ISA blocker. Next: Milestone 4,
the generated resident catalog and autostart metadata.

### Milestone 4 -- Generated Catalog and Autostart

- [x] TOML manifest for programs and services
- [x] Build tool generates PL/SW descriptor table from manifest
- [x] `AUTOSTART` flag launches the shell service at boot
- [x] Shell `run <name>` looks up and dispatches resident programs
- [x] Scheduled shell dispatch creates a separate process
- [x] Primary interactive menu uses the scheduler-integrated image
- [x] `ls` lists catalog entries
- [x] Per-process stack/state allocation for multiple instances

**Demo:** `run hello`, `run counter`, `run ipc-demo` all work from catalog.

**Status:** The manifest currently catalogs the resident `hello`, `counter`,
and `clock` programs plus the `shell` service. The deterministic generated
table contains name, kind, linked entry, image metadata, stack size, state
size, and flags for every object. `just autostart-smoke` proves boot scans the
flags and invokes the shell's catalog entry without a direct `CALL MENU`.
The current interactive system has no independently scheduled PL/SW TTY
service yet, so the shell is the first autostart service; TTY autostart will use
the same path when that service is separated. `just catalog-run-smoke` proves
`run counter` dispatches the matching program and a missing name is rejected.
The compatibility image dispatches synchronously; the primary scheduled image
routes the corresponding names through `TASK_SPAWN`.
`just catalog-list-smoke` proves `ls` enumerates all three programs and the
shell service without leaking its line ending into the next prompt.
`just catalog-spawn-smoke` consumes resident descriptor entry, stack, and state
fields to create two runnable contexts. Both share one counter entry point but
receive separate zeroed EBR state blocks and produce `A1 B1 A2 B2`. The counter
is a separately compiled PL/SW library module linked to the assembly scheduler;
an entry trampoline converts the initial register state pointer into a PL/SW
argument. Boot creates only the first task; that running PL/SW process calls
`TASK_SPAWN(descriptor)`, passing a resident descriptor pointer from its private
state. The service consumes that selected descriptor to allocate and insert the
second runnable process without disturbing the caller's live frames. Both use the exported
scheduler step/yield service. The process ABI has an explicit state pointer.
The proof also keeps the kernel stack at
`0xFEEC00` separate from the process arena starting at `0xFEE800`; allocating
below `0xFEE000` would leave the installed EBR window. The language/kernel ABI
bridge and generic descriptor-driven runtime spawn entry are now proven.

`just scheduled-shell-smoke` now links a writable-global-free persistent PL/SW
menu, Hello, Counter, and Clock with that scheduler. Choices `1`, `2`, and `3`
pass their private-state descriptor pointers to `TASK_SPAWN`. Hello blocks for
a key in its own process; Counter cooperatively produces `B1 B2`; Clock decodes
timestamped UART frames and logs `mm:ss` until Escape. All call `TASK_EXIT`,
which marks the slot free, clears the spawn guard, and restores the menu's
saved context. The scripted `1`, key, `2`, `3`, heartbeat frames, Escape, `0`
sequence proves all app paths and slot reuse. The kernel exports the PL/SW
division helper required for Clock conversion.
`just scheduled-shell-interactive` uses the generalized heartbeat frontend;
a real PTY run proves Ctrl-] returns from Clock and `0` halts.
`just plsw-system-interactive` now builds and runs this scheduler image, and
`plsw-system-run` remains its alias. The former direct-call catalog shell is
retained as `just plsw-system-compat-interactive`.
`just scheduled-catalog-smoke` proves the primary shell handles `ls` and
`run counter` by walking the generated scheduler table, rejects missing names
and the non-program shell service, and reuses the process slot. The shell no
longer contains literal catalog names or app-specific yield counts: a generic
join service suspends it until the spawned app calls `TASK_EXIT`. Scheduler
descriptor records and name storage are generated from
`catalog/catalog.toml`; the kernel no longer contains hand-maintained Hello,
Counter, Clock, or shell descriptors. The manifest's larger stack/state sizes
also pass within the installed EBR window using a process-arena high address of
`0xFEEB00`. `TASK_SPAWN` saves the arena pointer before allocating the first
child in a generation, and the last child to call `TASK_EXIT` restores that
mark. This releases all child state and stacks together while preserving the
persistent shell below them. `just scheduled-reclaim-smoke` completes 20 sequential Counter launches,
which exceeds the former bump-only arena capacity, and verifies all 20 private
states restart at `B1`. The scheduler now scans three contiguous process-table
entries for the next runnable slot. `just scheduled-multislot-smoke` spawns two
Counter children concurrently and proves round-robin `B1 C1 B2 C2` output,
independent zeroed state, free-slot selection, join-on-all-children, and
generation reclamation. A kernel process-table listing service is wired to the
scheduled shell: `ps` reports stable endpoint identities and symbolic `FREE` or
`RUNNABLE` states for all three slots. Scheduled catalog coverage proves the
idle shell view, while the multislot proof calls the same service after two
spawns and observes all three slots runnable. Milestone 5 is complete. Next:
define the embedded COR24 executable header and add generator-side validation
for the first Milestone 6 image blob.

### Milestone 5 -- Process-Local State

- [x] Shared resident text, private stack + state block
- [x] Multiple instances of the same program (e.g., two counters)
- [x] Process-global state accessed only via passed state pointer
- [x] `ps` shows all processes with endpoints and states

### Milestone 6 -- Embedded Executable Blobs

- [x] COR24 executable format (magic, version, text/data/bss sizes, entry)
- [ ] Loader: allocate RAM, copy text/data, clear BSS, apply relocations
- [ ] Same `run` command works for both resident and embedded programs

**Status:** The versioned header, deterministic builder, strict validator, and
corruption coverage are complete. Version 1 deliberately requires zero
relocations. Next: add an in-memory loader proof that copies text/data to an
allocated region, clears BSS, and returns the relocated entry address.

### Milestone 7 -- SPI Image Provider (Future)

- [ ] SPI block device HAL driver
- [ ] SPI catalog provider (same interface as resident provider)
- [ ] Programs loaded from SPI flash transparently

---

## 16. Toolchain and Build

- **Language:** PL/SW (PL/I-inspired systems programming language for COR24)
  -- [sw-cor24-plsw](https://github.com/sw-embed/sw-cor24-plsw)
- **Assembler:** COR24 assembler (`cor24-asm`)
- **Emulator:** `cor24-emu` (Rust-based COR24 emulator)
- **Compiler:** PL/SW compiler binary (`tools/plsw.lgo`, pre-built from
  sw-cor24-plsw). Runs as a COR24 program on the emulator.
- **Linker:** `link24` (FIXUP-based linker from sw-cor24-plsw toolchain)
- **ABI:** COR24 calling convention: args on stack R-to-L, return in r0,
  8 registers (r0-r2 GP, fp, sp, z, iv, ir), 24-bit word-addressable
- **Build system:** justfile
- **Output:** flat binary image (.lgo) loadable via COR24 serial boot
  (921,600 baud)
- **Entire system:** one monolithic binary (kernel + services + apps + catalog)

### PL/SW Pipeline

The PL/SW compiler runs on the COR24 emulator -- it is itself a COR24
program, not a host tool. Source is fed via UART using the FILE:/SOURCE:
protocol:

```
.plsw + .msw files  -->  pipeline.sh  -->  compiler on emulator (via --uart-file)
                                               |
                                           .s assembly
                                               |
                                          cor24-asm  -->  .lgo image
                                               |
                                          cor24-emu  -->  program output
```

**Important:** Use `--uart-file` to feed source to the compiler, NOT `-u`.
The `-u` flag has a bug where the `SOURCE:` prefix causes character loss
in the FILE:/SOURCE: protocol. `--uart-file` writes raw bytes to a temp
file and feeds them correctly.

### FILE:/SOURCE: Protocol

For multi-file compilation with .msw includes:

1. Send `c\n` to enter compile mode
2. For each .msw: `FILE:<name>\n<content>\x1E` (record separator)
3. `SOURCE:\n<main source>\x04` (EOT)

The name in `FILE:` must match the `%INCLUDE` name (without .msw).

### Justfile Recipes

| Recipe              | Description                                |
|---------------------|--------------------------------------------|
| `just plsw-smoke`   | Compile smoke-test.plsw with .msw includes |
| `just plsw-smoke-run` | Compile and run smoke-test.plsw         |
| `just plsw-system`  | Compile the complete menu system to `.lgo` and `.bin` |
| `just plsw-system-interactive` | Build and run the scheduler-integrated menu |
| `just plsw-system-run` | Alias for `plsw-system-interactive` |
| `just plsw-system-compat-interactive` | Run the former direct-call catalog shell |
| `just plsw-link-smoke` | Compile, FIXUP-link, and run separate PL/SW modules |
| `just context-switch-smoke` | Verify two-task cooperative context switching |
| `just cooperative-fallback-smoke` | Verify scheduling and IPC without heartbeat synchronization |
| `just ipc-smoke` | Verify blocking fixed-message client/TTY IPC |
| `just heartbeat-smoke` | Verify UART framing and 24-bit clock wraparound |
| `just clock-smoke` | Verify the heartbeat-driven PL/SW Clock menu app |
| `just catalog-smoke` | Validate, generate, and compile the resident catalog |
| `just cor24-image-smoke` | Build and corruption-test a versioned COR24 image |
| `just autostart-smoke` | Verify metadata-driven shell service startup |
| `just catalog-run-smoke` | Verify shell catalog lookup and program dispatch |
| `just catalog-list-smoke` | Verify shell enumeration of catalog descriptors |
| `just catalog-spawn-smoke` | Verify descriptor-sized stack/state process creation |
| `just scheduled-shell-smoke` | Verify shell-to-spawn scheduled PL/SW dispatch |
| `just scheduled-catalog-smoke` | Verify scheduled `ls` and `run <name>` commands |
| `just scheduled-reclaim-smoke` | Stress repeated app stack/state reclamation |
| `just scheduled-multislot-smoke` | Schedule two concurrent private-state children |
| `just scheduled-shell-interactive` | Run the scheduler-integrated shell proof |
| `just plsw-compile <[.msw ...] file.plsw>` | Compile any .plsw  |
| `just plsw-run <[.msw ...] file.plsw>` | Compile and run any .plsw |
| `just plsw-dump <[.msw ...] file.plsw>` | Compile and dump memory |
| `just smoke`         | Assemble smoke-test.s (assembly, not PL/SW) |
| `just run`           | Run assembly smoke test                   |

---

## 17. Risk and Constraints

| Risk                              | Mitigation                                    |
|-----------------------------------|-----------------------------------------------|
| No MMU                            | Single address space; logical isolation by convention |
| No hardware timer                 | UART-hosted virtual timer with cooperative fallback |
| No hardware multiply              | Compiler runtime helpers (`__mul24` etc.)      |
| 1 MB RAM very limited             | Fixed regions; resident shared text; minimal kernel |
| PL/SW systems constructs unknown | Milestone 0 validates PL/SW for OS use |
| UART ISR cannot save/load `ir` for preemption | Keep cooperative scheduling; consider an ISA or interrupt-ABI extension |
| Host disconnect stops clock       | Cooperative fallback; clock status visible    |
| 24-bit char breaks `CHAR_BIT==8` assumptions | Use `octet_t` for serialized data; avoid `char` tricks |
| Terminal sends control bytes      | Escape framing protocol                      |
| USB-UART buffering jitter         | Use elapsed host tick counter, not interrupt count |
| Binary loader conflicts with heartbeat | Unified escaped transport                   |

---

## 18. Reference Materials

- MINIX 1 architecture and IPC design (Tanenbaum, 1987) -- conceptual reference only
- COR24-TB user manual (`COR24-TB-MAN.pdf`)
- COR24 release notes (2026/07/15, commit `bd805538f6`)
- Existing COR24 demo: `loadngo` monitor (serial boot protocol reference)
- Existing COR24 demo: `uartintr` (UART interrupt test)
- PL/SW compiler and toolchain: [sw-cor24-plsw](https://github.com/sw-embed/sw-cor24-plsw)
- Lattice MachXO FPGA reference manual
