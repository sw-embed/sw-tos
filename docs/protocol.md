# SWTOS Multiplexed Transport

Version 1 frames use this byte layout:

```text
A5 5A | version | type | channel | length-low | length-high | payload | checksum
```

The checksum is the wrapping eight-bit sum of every byte from `version`
through the final payload byte. Length is an unsigned little-endian payload
length and is limited to 1024 bytes by the host implementation.

Version 1 message types are TTY input/output, channel open/close/title, uptime,
wall clock, resource snapshot, debugger request/response, and protocol error.
Types 12 and 13 are HELLO and HELLO_ACK. Their channel is zero and their exact
payload is `SWT1`. Both peers remain in plain recovery mode until a valid ACK;
disconnect immediately returns the host to plain mode.
Channels are logical virtual-TTY identifiers; channel zero is reserved for
system-wide traffic where a message type does not belong to one TTY.

Decoders scan for the two-byte synchronization sequence and retain a trailing
`A5` across fragmented reads. Bad versions, lengths, checksums, and unknown
types discard only the current synchronization candidate, allowing the next
valid frame to be recovered even when its synchronization bytes occur inside
the corrupt candidate. Payload bytes are never escaped, including literal
`A5 5A` sequences. A reconnect clears any partial frame before accepting the
new stream.

The unframed UART terminal remains the recovery transport during migration.
Framed mode will become active only after target negotiation, so an older host
or a plain terminal cannot accidentally turn ordinary application bytes into
control messages.
