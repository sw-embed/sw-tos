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

## 4. COR24 C Data Model

| C Type         | Representation                  |
|----------------|----------------------------------|
| `char`         | 24 bits (one character per word) |
| `short`        | 24 bits                          |
| `int` / `unsigned` | 24 bits                       |
| `pointer`      | 24 bits                          |
| `long`         | 48 bits (two words), optional    |
| `long long`    | unsupported                      |
| `float`/`double` | unsupported                    |

Local typedefs make intent explicit:

```c
typedef unsigned cor_word_t;
typedef unsigned cor_addr_t;
typedef unsigned endpoint_t;
typedef unsigned octet_t;      /* UART char, constrained to 0..255 */
```

One character per 24-bit word wastes memory but keeps the compiler, pointer
arithmetic, UART driver, shell, and data handling simple. Optimize packing
later if needed.

### Compiler Runtime Helpers (no hardware multiply)

```c
unsigned __mul24(unsigned a, unsigned b);
unsigned __umul24(unsigned a, unsigned b);
unsigned __div24(unsigned a, unsigned b);
unsigned __udiv24(unsigned a, unsigned b);
unsigned __mod24(unsigned a, unsigned b);
unsigned __umod24(unsigned a, unsigned b);
```

Tiny C emits calls to these when the COR24 ISA lacks native instructions.

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
        proc.c          process table, spawn, exit
        sched.c         scheduler (cooperative + preemptive)
        ipc.c           send, receive, sendrec
        clock.c         heartbeat timer, sleep queue
        syscall.c       system call dispatch
        heap.c          kernel memory allocator
    hal/
        cor24/
            boot.s       reset vector, stack init
            interrupt.s  interrupt entry/exit
            context.s    save/restore registers, context switch
            uart.s       raw UART access
            gpio.s       GPIO access
    services/
        tty.c           TTY service (polled then interrupt-driven)
        shell.c         command interpreter
    catalog/
        catalog.c       find, list, spawn from catalog
        manifest.py     build tool: TOML -> descriptor table
    apps/
        hello.c
        counter.c
        ps.c
        ipc_demo.c
        sleep_demo.c
        mem.c
        uptime.c
    include/
        swtos.h         master header
        kernel.h
        proc.h
        ipc.h
        message.h
        catalog.h
        hal.h
    lib/
        printf.c
        string.c
        memset.c
        memcpy.c
    build/
        Makefile
        link.ld         linker script
```

---

## 15. Development Milestones

### Milestone 0 -- Tiny C ABI Readiness

Before importing any OS code, prove Tiny C can build:

- [ ] Structures and arrays of structures
- [ ] Pointers to structures, function pointers
- [ ] Separate C and assembly objects linked together
- [ ] Recursion-free stack use
- [ ] Global/static initialization
- [ ] Software multiply/divide runtime helpers
- [ ] Volatile UART register access

**Deliverable:** `abi-test.bin` running identically in the Rust emulator
and on COR24-TB hardware.

### Milestone 1 -- Linked Tasks with Context Switch

- [ ] Boot stub: init UART, print banner
- [ ] Static task table with 2-3 tasks
- [ ] Separate stacks allocated from heap
- [ ] Assembly context save/restore
- [ ] Cooperative `yield()` round-robin
- [ ] Polled UART output from tasks

**Demo:** Tasks alternate printing: `A: 1`, `B: 1`, `A: 2`, `B: 2`

### Milestone 2 -- MINIX-Style IPC

- [ ] `send()`, `receive()`, `sendrec()` in kernel
- [ ] Fixed-size message struct
- [ ] Blocking semantics (process blocks if peer not ready)
- [ ] TTY as a service task receiving `TTY_WRITE` messages

**Demo:** Client process sends a string to TTY service; TTY prints it.

### Milestone 3 -- UART Heartbeat Clock

- [ ] Escape framing in UART ISR
- [ ] 24-bit heartbeat counter with wraparound
- [ ] Monotonic tick counter in kernel
- [ ] Sleep queue with tick-based wakeup
- [ ] Preemptive scheduling from ISR (if COR24 supports context
  switch from interrupt return)
- [ ] Cooperative fallback when no heartbeat

**Demo:** CPU-bound process preempted; shell remains responsive.
Sleep command works.

### Milestone 4 -- Generated Catalog and Autostart

- [ ] TOML manifest for programs and services
- [ ] Build tool generates C descriptor table
- [ ] `AUTOSTART` flag launches TTY service at boot
- [ ] Shell `run <name>` spawns from catalog
- [ ] `ls` lists catalog entries
- [ ] Per-process state allocation for multiple instances

**Demo:** `run hello`, `run counter`, `run ipc-demo` all work from catalog.

### Milestone 5 -- Process-Local State

- [ ] Shared resident text, private stack + state block
- [ ] Multiple instances of the same program (e.g., two counters)
- [ ] Process-global state accessed only via passed state pointer
- [ ] `ps` shows all processes with endpoints and states

### Milestone 6 -- Embedded Executable Blobs (Later)

- [ ] COR24 executable format (magic, version, text/data/bss sizes, entry)
- [ ] Loader: allocate RAM, copy text/data, clear BSS, apply relocations
- [ ] Same `run` command works for both resident and embedded programs

### Milestone 7 -- SPI Image Provider (Future)

- [ ] SPI block device HAL driver
- [ ] SPI catalog provider (same interface as resident provider)
- [ ] Programs loaded from SPI flash transparently

---

## 16. Toolchain and Build

- **C compiler/assembler/linker:** Tiny C (COR24 target)
- **ABI questions to resolve first:** argument passing (registers vs stack),
  callee-saved vs caller-saved registers, stack frame layout, structure
  alignment, can C call assembly and vice versa, can linker place sections
  at specific addresses, can it emit relocatable objects
- **Build system:** Makefile
- **Output:** flat binary image loadable via COR24 serial boot (921,600 baud)
- **Entire system:** one monolithic binary (kernel + services + apps + catalog)

---

## 17. Risk and Constraints

| Risk                              | Mitigation                                    |
|-----------------------------------|-----------------------------------------------|
| No MMU                            | Single address space; logical isolation by convention |
| No hardware timer                 | UART-hosted virtual timer with cooperative fallback |
| No hardware multiply              | Compiler runtime helpers (`__mul24` etc.)      |
| 1 MB RAM very limited             | Fixed regions; resident shared text; minimal kernel |
| Tiny C ABI unknowns               | Milestone 0 validates ABI before OS work    |
| UART ISR must support context switch for preemption | Verify COR24 interrupt return semantics early |
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
- MakerLisp COR24 C compiler and tools package (separate archive, contact MakerLisp)
- Lattice MachXO FPGA reference manual
