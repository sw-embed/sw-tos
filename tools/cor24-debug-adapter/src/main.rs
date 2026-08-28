use cor24_emulator::cpu::state::UartDirection;
use cor24_emulator::emulator::{EmulatorCore, StopReason};
use serde_json::Value;
use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::FromRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::time::Duration;

const SYNC: [u8; 2] = [0xa5, 0x5a];
const DEBUG_REQUEST: u8 = 9;
const DEBUG_RESPONSE: u8 = 10;
const HELLO: u8 = 12;
const TTY_INPUT: u8 = 1;
const UPTIME: u8 = 6;
const WALL_CLOCK: u8 = 7;
const RESOURCE_SNAPSHOT: u8 = 8;
// Emulator-test transport command: inject payload bytes directly into the
// modeled UART. This is intentionally outside protocol v1's target kinds and
// is required for the out-of-band FF 01 scheduler heartbeat used on hardware.
const RAW_UART: u8 = 0xfe;
const TARGET_BYTE_CYCLES: u64 = 500_000;
// Heartbeats arrive at 100 Hz. The UART ISR consumes each byte in far fewer
// cycles; using the full target-frame budget here makes the emulator adapter
// fall behind real time and starves outbound Resources snapshots.
const HEARTBEAT_BYTE_CYCLES: u64 = 20_000;

fn main() -> Result<(), String> {
    let mut args = env::args().skip(1);
    let image = args.next().ok_or("usage: adapter IMAGE DEBUG_MAP PTY")?;
    let map_path = args.next().ok_or("usage: adapter IMAGE DEBUG_MAP PTY")?;
    let pty = args.next().ok_or("usage: adapter IMAGE DEBUG_MAP PTY")?;
    if args.next().is_some() {
        return Err("usage: adapter IMAGE DEBUG_MAP PTY".into());
    }

    let map: Value =
        serde_json::from_str(&fs::read_to_string(&map_path).map_err(err)?).map_err(err)?;
    let build_id = map["build_id"]
        .as_str()
        .ok_or("debug map has no build_id")?;
    let build_id = u32::from_str_radix(build_id.strip_prefix("crc24:").ok_or("bad build_id")?, 16)
        .map_err(err)?;

    let mut emu = EmulatorCore::new();
    emu.load_program(0, &fs::read(&image).map_err(err)?);
    emu.set_pc(0);
    // SWTOS owns memory outside the emulator's default standalone stack window.
    emu.set_stack_bounds(0, 0);

    let mut io = if let Some(fd) = pty.strip_prefix("fd:") {
        let fd = fd.parse::<i32>().map_err(err)?;
        // SAFETY: the launcher explicitly passes ownership of this inherited fd.
        unsafe { File::from_raw_fd(fd) }
    } else {
        OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(libc_nonblock())
            .open(pty)
            .map_err(err)?
    };
    let mut decoder = Decoder::default();
    let mut uart_log_seen = 0usize;
    let mut input = [0u8; 4096];
    loop {
        match io.read(&mut input) {
            Ok(0) => return Ok(()),
            Ok(n) => {
                for frame in decoder.push(&input[..n]) {
                    handle_frame(&mut emu, build_id, frame, &mut io, &mut uart_log_seen)?;
                }
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
            Err(error) => return Err(error.to_string()),
        }
        if emu.is_running() {
            let result = emu.run_batch(50_000);
            flush_uart(&mut emu, &mut io, &mut uart_log_seen)?;
            if !matches!(result.reason, StopReason::CycleLimit) {
                write_debug(&mut io, stop_payload(&emu, &result.reason))?;
            }
        }
        std::thread::sleep(Duration::from_millis(1));
    }
}

fn handle_frame(
    emu: &mut EmulatorCore,
    _build_id: u32,
    frame: Frame,
    io: &mut File,
    uart_log_seen: &mut usize,
) -> Result<(), String> {
    match (frame.kind, frame.payload.as_slice()) {
        (RAW_UART, bytes) => feed_uart_bytes(
            emu,
            bytes,
            HEARTBEAT_BYTE_CYCLES,
            io,
            uart_log_seen,
        ),
        // These operations are implemented by SWTOS itself so endpoint
        // register snapshots and process termination use scheduler-owned
        // saved contexts identically on the emulator and physical board.
        (DEBUG_REQUEST, [1] | [13, _]) => {
            feed_target_frame(emu, &frame, io, uart_log_seen)
        }
        // While execution is stopped, endpoint 1 is the debugger's raw CPU
        // context. While running, endpoint requests belong to SWTOS and report
        // coherent scheduler-owned process contexts on emulator and hardware.
        (DEBUG_REQUEST, [2, endpoint]) if !emu.is_running() => {
            let snap = emu.snapshot();
            let mut first = vec![2, *endpoint, 0];
            for value in [snap.regs[0], snap.regs[1], snap.regs[2], snap.regs[4]] {
                put24(&mut first, value);
            }
            write_debug(io, first)?;
            let mut second = vec![2, *endpoint, 1];
            for value in [snap.pc, u32::from(snap.c) | (u32::from(snap.halted) << 1)] {
                put24(&mut second, value);
            }
            write_debug(io, second)
        }
        (DEBUG_REQUEST, [2, _]) => feed_target_frame(emu, &frame, io, uart_log_seen),
        (DEBUG_REQUEST, [3, a0, a1, a2, length]) if !emu.is_running() => {
            let address = u24(*a0, *a1, *a2);
            let mut response = vec![3, *a0, *a1, *a2];
            response.extend(emu.read_memory(address, u32::from((*length).min(64))));
            write_debug(io, response)
        }
        (DEBUG_REQUEST, [3, _, _, _, _]) => feed_target_frame(emu, &frame, io, uart_log_seen),
        (HELLO, b"SWT1") => feed_target_frame(emu, &frame, io, uart_log_seen),
        (kind, _) if target_frame(kind) => feed_target_frame(emu, &frame, io, uart_log_seen),
        (DEBUG_REQUEST, [4]) => {
            emu.pause();
            write_debug(io, stop_payload(emu, &StopReason::Paused))
        }
        (DEBUG_REQUEST, [5]) => {
            emu.resume();
            write_debug(io, stop_payload(emu, &StopReason::CycleLimit))
        }
        (DEBUG_REQUEST, [6, a0, a1, a2]) => {
            let address = u24(*a0, *a1, *a2);
            emu.add_breakpoint(address);
            write_debug(io, breakpoint_payload(emu))
        }
        (DEBUG_REQUEST, [7, a0, a1, a2]) => {
            let address = u24(*a0, *a1, *a2);
            emu.remove_breakpoint(address);
            write_debug(io, breakpoint_payload(emu))
        }
        (DEBUG_REQUEST, [8]) => write_debug(io, breakpoint_payload(emu)),
        (DEBUG_REQUEST, [9]) => {
            let result = emu.step();
            write_debug(io, stop_payload(emu, &result.reason))
        }
        (DEBUG_REQUEST, [10]) => {
            let result = emu.step_over();
            write_debug(io, stop_payload(emu, &result.reason))
        }
        (DEBUG_REQUEST, [11]) => {
            let snap = emu.snapshot();
            let mut response = vec![11];
            put24(&mut response, snap.pc);
            put24(&mut response, snap.regs[3]);
            put24(&mut response, snap.regs[4]);
            // PL/SW saves the caller FP and return PC immediately below FP.
            for offset in 0..8u32 {
                put24(
                    &mut response,
                    emu.read_word(snap.regs[3].wrapping_add(offset * 3)),
                );
            }
            write_debug(io, response)
        }
        (DEBUG_REQUEST, [12]) => {
            write_debug(io, vec![12])?;
            std::process::exit(0);
        }
        _ => write_debug(io, vec![0xff, 1]),
    }
}

fn target_frame(kind: u8) -> bool {
    matches!(kind, TTY_INPUT | UPTIME | WALL_CLOCK | RESOURCE_SNAPSHOT)
}

fn stop_payload(emu: &EmulatorCore, reason: &StopReason) -> Vec<u8> {
    let code = match reason {
        StopReason::Breakpoint(_) => 1,
        StopReason::Paused => 2,
        StopReason::CycleLimit => 3,
        StopReason::Halted => 4,
        StopReason::InvalidInstruction(_) => 5,
        StopReason::StackOverflow(_) => 6,
        StopReason::StackUnderflow(_) => 7,
    };
    let mut payload = vec![4, code];
    put24(&mut payload, emu.pc());
    payload
}

fn breakpoint_payload(emu: &EmulatorCore) -> Vec<u8> {
    let mut payload = vec![8, emu.breakpoints().len().min(255) as u8];
    for &address in emu.breakpoints() {
        put24(&mut payload, address);
    }
    payload
}

fn flush_uart(
    emu: &mut EmulatorCore,
    io: &mut File,
    uart_log_seen: &mut usize,
) -> Result<(), String> {
    let entries = emu.uart_log().entries();
    let bytes = entries[*uart_log_seen..]
        .iter()
        .filter(|entry| entry.direction == UartDirection::Output)
        .map(|entry| entry.byte)
        .collect::<Vec<_>>();
    *uart_log_seen = entries.len();
    if !bytes.is_empty() {
        write_all_retrying(io, &bytes)?;
        emu.clear_uart_output();
    }
    Ok(())
}

fn write_debug(io: &mut File, payload: Vec<u8>) -> Result<(), String> {
    write_frame(io, DEBUG_RESPONSE, 0, &payload)
}
/// Write every byte to the pseudo-terminal, waiting out a full output buffer.
///
/// The adapter's descriptor is non-blocking, and `write_all` reports
/// `WouldBlock` instead of retrying, so any emulator burst larger than the
/// pseudo-terminal could hold killed the adapter outright. Darwin buffers
/// roughly 1 KiB where Linux buffers about 8 KiB, which made an ordinary
/// `ls` enough to lose the session on macOS. Retry until the frontend drains
/// the pipe. A frontend that has actually gone away fails with EIO rather
/// than EAGAIN, so a genuine hangup still ends the loop.
fn write_all_retrying<W: Write>(io: &mut W, bytes: &[u8]) -> Result<(), String> {
    let mut pending = bytes;
    while !pending.is_empty() {
        match io.write(pending) {
            Ok(0) => return Err("pseudo-terminal accepted no bytes".into()),
            Ok(written) => pending = &pending[written..],
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                ) =>
            {
                std::thread::sleep(Duration::from_millis(1));
            }
            Err(error) => return Err(err(error)),
        }
    }
    Ok(())
}

fn write_frame(io: &mut File, kind: u8, channel: u8, payload: &[u8]) -> Result<(), String> {
    let len = payload.len() as u16;
    let mut bytes = vec![
        SYNC[0],
        SYNC[1],
        1,
        kind,
        channel,
        len as u8,
        (len >> 8) as u8,
    ];
    bytes.extend(payload);
    bytes.push(
        bytes[2..]
            .iter()
            .fold(0u8, |sum, byte| sum.wrapping_add(*byte)),
    );
    write_all_retrying(io, &bytes)
}

#[derive(Default)]
struct Decoder {
    bytes: Vec<u8>,
}
struct Frame {
    kind: u8,
    channel: u8,
    payload: Vec<u8>,
}
impl Decoder {
    fn push(&mut self, input: &[u8]) -> Vec<Frame> {
        self.bytes.extend(input);
        let mut frames = Vec::new();
        loop {
            if self.bytes.starts_with(&[0xff, 1]) {
                if self.bytes.len() < 5 {
                    break;
                }
                frames.push(Frame {
                    kind: RAW_UART,
                    channel: 0,
                    payload: self.bytes[..5].to_vec(),
                });
                self.bytes.drain(..5);
                continue;
            }
            let framed = self.bytes.windows(2).position(|v| v == SYNC);
            let heartbeat = self.bytes.windows(2).position(|v| v == [0xff, 1]);
            let pos = match (framed, heartbeat) {
                (Some(a), Some(b)) => a.min(b),
                (Some(pos), None) | (None, Some(pos)) => pos,
                (None, None) => {
                    if self.bytes.last().is_some_and(|byte| [0xa5, 0xff].contains(byte)) {
                        let last = *self.bytes.last().expect("checked above");
                        self.bytes.clear();
                        self.bytes.push(last);
                    } else {
                        self.bytes.clear();
                    }
                    break;
                }
            };
            self.bytes.drain(..pos);
            if self.bytes.starts_with(&[0xff, 1]) {
                continue;
            }
            if self.bytes.len() < 8 {
                break;
            }
            let len = usize::from(self.bytes[5]) | (usize::from(self.bytes[6]) << 8);
            if self.bytes.len() < len + 8 {
                break;
            }
            let end = len + 8;
            let checksum = self.bytes[2..end - 1]
                .iter()
                .fold(0u8, |sum, byte| sum.wrapping_add(*byte));
            if checksum == self.bytes[end - 1] && self.bytes[2] == 1 {
                frames.push(Frame {
                    kind: self.bytes[3],
                    channel: self.bytes[4],
                    payload: self.bytes[7..end - 1].to_vec(),
                });
            }
            self.bytes.drain(..end);
        }
        frames
    }
}

fn feed_target_frame(
    emu: &mut EmulatorCore,
    frame: &Frame,
    io: &mut File,
    uart_log_seen: &mut usize,
) -> Result<(), String> {
    let bytes = encoded_frame(frame.kind, frame.channel, &frame.payload);
    feed_uart_bytes(emu, &bytes, TARGET_BYTE_CYCLES, io, uart_log_seen)
}

fn feed_uart_bytes(
    emu: &mut EmulatorCore,
    bytes: &[u8],
    cycles_per_byte: u64,
    io: &mut File,
    uart_log_seen: &mut usize,
) -> Result<(), String> {
    for &byte in bytes {
        emu.send_uart_byte(byte);
        emu.resume();
        let result = emu.run_batch(cycles_per_byte);
        if !matches!(result.reason, StopReason::CycleLimit) {
            write_debug(io, stop_payload(emu, &result.reason))?;
        }
    }
    flush_uart(emu, io, uart_log_seen)
}

fn encoded_frame(kind: u8, channel: u8, payload: &[u8]) -> Vec<u8> {
    let len = payload.len() as u16;
    let mut bytes = vec![
        SYNC[0],
        SYNC[1],
        1,
        kind,
        channel,
        len as u8,
        (len >> 8) as u8,
    ];
    bytes.extend(payload);
    bytes.push(
        bytes[2..]
            .iter()
            .fold(0u8, |sum, byte| sum.wrapping_add(*byte)),
    );
    bytes
}

fn put24(out: &mut Vec<u8>, value: u32) {
    out.extend([value as u8, (value >> 8) as u8, (value >> 16) as u8]);
}
fn u24(a: u8, b: u8, c: u8) -> u32 {
    u32::from(a) | (u32::from(b) << 8) | (u32::from(c) << 16)
}
fn err(error: impl std::fmt::Display) -> String {
    error.to_string()
}
#[cfg(target_os = "linux")]
fn libc_nonblock() -> i32 {
    0o4000
}
#[cfg(not(target_os = "linux"))]
fn libc_nonblock() -> i32 {
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn routes_target_control_without_hiding_debug_requests() {
        for kind in [TTY_INPUT, UPTIME, WALL_CLOCK, RESOURCE_SNAPSHOT] {
            assert!(target_frame(kind));
        }
        assert!(!target_frame(DEBUG_REQUEST));
        assert!(!target_frame(HELLO));
    }

    /// Accepts bytes only after refusing a fixed number of times, and never
    /// more than `chunk` per call, like a pseudo-terminal whose buffer is
    /// full and then partially drained by the frontend.
    struct FullBuffer {
        refusals: usize,
        chunk: usize,
        accepted: Vec<u8>,
    }

    impl Write for FullBuffer {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            if self.refusals > 0 {
                self.refusals -= 1;
                return Err(io::Error::from(io::ErrorKind::WouldBlock));
            }
            let written = self.chunk.min(buf.len());
            self.accepted.extend_from_slice(&buf[..written]);
            Ok(written)
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    struct FailingWriter(io::ErrorKind);

    impl Write for FailingWriter {
        fn write(&mut self, _: &[u8]) -> io::Result<usize> {
            Err(io::Error::from(self.0))
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn a_full_pseudo_terminal_delays_output_instead_of_ending_the_session() {
        // The descriptor is non-blocking, so write_all reports WouldBlock
        // rather than retrying. Treating that as fatal killed the adapter on
        // any burst larger than the pseudo-terminal buffer, which on Darwin
        // is roughly 1 KiB, so an ordinary `ls` was enough.
        let payload: Vec<u8> = (0..4096).map(|index| index as u8).collect();
        let mut sink = FullBuffer {
            refusals: 3,
            chunk: 7,
            accepted: Vec::new(),
        };
        write_all_retrying(&mut sink, &payload).expect("a full buffer must not be fatal");
        assert_eq!(sink.accepted, payload, "every byte arrives, in order");
    }

    #[test]
    fn a_departed_frontend_still_ends_the_session() {
        for kind in [io::ErrorKind::BrokenPipe, io::ErrorKind::NotConnected] {
            let mut sink = FailingWriter(kind);
            assert!(
                write_all_retrying(&mut sink, b"payload").is_err(),
                "{kind:?} must not be retried forever"
            );
        }
    }

    #[test]
    fn decoder_preserves_raw_scheduler_heartbeats_between_target_frames() {
        let mut decoder = Decoder::default();
        let target = encoded_frame(TTY_INPUT, 0, b"x");
        let mut stream = target.clone();
        stream.extend([0xff, 1, 0x34, 0x12, 0]);
        assert!(decoder.push(&stream[..3]).is_empty());
        let frames = decoder.push(&stream[3..]);
        assert_eq!(frames.len(), 2);
        assert_eq!(frames[0].kind, TTY_INPUT);
        assert_eq!(frames[0].payload, b"x");
        assert_eq!(frames[1].kind, RAW_UART);
        assert_eq!(frames[1].payload, [0xff, 1, 0x34, 0x12, 0]);
    }
}
