# SWTOS Multiplexed Transport

Version 1 frames use this byte layout:

```text
A5 5A | version | type | channel | length-low | length-high | payload | checksum
```

The checksum is the wrapping eight-bit sum of every byte from `version`
through the final payload byte. Length is an unsigned little-endian payload
length. The host accepts at most 1024 bytes and the bounded COR24 decoder
accepts at most 16 bytes per frame.

Version 1 message types are TTY input/output, channel open/close/title, uptime,
wall clock, resource snapshot, debugger request/response, and protocol error.
Types 12 and 13 are HELLO and HELLO_ACK. Their channel is zero and their exact
payload is `SWT1`. Both peers remain in plain recovery mode until a valid ACK.
The Rust host sends HELLO only when `--framed` is requested and returns to plain
mode on disconnect. The target accepts another exact HELLO while framed, so a
reconnected frontend can negotiate without rebooting the target.

Two unframed ISR control escapes remain available inside framed passthrough
records: `FF 04` requests a shell-only restart and `FF 05` requests a warm
system reboot. The latter clears endpoints 2 through 16 in full—including
statistics, preemption sidecars, and virtual TTY rings—resets the child
allocation generation, and rewinds endpoint 1. Both requests are deferred to
a safe shell kernel boundary; neither substitutes for physical reset if UART
interrupts or scheduler progress have stopped.
Channels are logical virtual-TTY identifiers; channel zero is reserved for
system-wide traffic where a message type does not belong to one TTY.

Decoders scan for the two-byte synchronization sequence and retain a trailing
`A5` across fragmented reads. Bad versions, lengths, checksums, and unknown
types discard only the current synchronization candidate, allowing the next
valid frame to be recovered even when its synchronization bytes occur inside
the corrupt candidate. Payload bytes are never escaped, including literal
`A5 5A` sequences. A reconnect clears any partial frame before accepting the
new stream.

The unframed UART terminal remains the recovery transport. Before negotiation,
ordinary bytes follow the foreground TTY path and plain target output is
unchanged. After negotiation, TTY input is routed by channel and each output
byte is emitted as an ordered TTY_OUTPUT frame for its owning process. Each
target input ring holds 16 bytes; a full ring drops the new byte and increments
that channel's overflow counter. Target output blocks on the UART transmitter,
using RTS/CTS as backpressure rather than silently dropping output.

UPTIME and WALL_CLOCK carry a three-byte little-endian centisecond value on
channel zero. SWTOS delivers them only to the foreground time consumer, outside
ordinary TTY input.

RESOURCE_SNAPSHOT uses channel zero. An empty host-to-target frame requests a
fresh generation; the target returns bounded records whose first two bytes are
record kind and wrapping generation. Kind 1 begins a generation. Kind 2 carries
24-bit little-endian arena current, arena peak, kernel-stack peak, allocation
failures, and used/total slots. Kind 3 carries endpoint, state, blocked reason,
16-bit stack/state sizes, dispatches, and yields. Kind 4 carries endpoint, IPC,
TTY input/output totals, and a four-byte display name. Kind 6 carries endpoint,
forced-preemption count, and the last interrupted `r0` CPU-progress sample.
Kind 5 ends the generation with protocol-error and UART receive/transmit totals. Hosts must discard partial
or mismatched generations and publish only after kind 5. A target response
record never exceeds the target decoder's 16-byte payload bound.

DEBUG_REQUEST and DEBUG_RESPONSE use channel zero. Opcode 1 requests the
target's build identity and returns the opcode plus a three-byte little-endian
CRC of the immutable executable range. Opcode 2 takes an endpoint and returns
its saved registers in two bounded records: `r0`, `r1`, `r2`, `sp`, then `pc`
and status. Opcode 3 takes a 24-bit address and a length from 1 through 12 and
returns those bytes with their starting address. Opcode 13 takes an endpoint
and queues termination only when the target is a certified runway process with
a complete parked interrupt context; its three-byte response is opcode,
endpoint, and status (zero means queued). Register reads do not cause a
preemption: opcode 2 reports the most recently parked coherent ISR frame.
Identity, register, and memory operations are read-only; kill is asynchronous
execution control and descriptor reclamation remains in the task-exit path.
