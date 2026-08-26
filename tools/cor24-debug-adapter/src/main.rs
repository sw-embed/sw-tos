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
const HELLO_ACK: u8 = 13;

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
    let mut input = [0u8; 4096];
    loop {
        match io.read(&mut input) {
            Ok(0) => return Ok(()),
            Ok(n) => {
                for frame in decoder.push(&input[..n]) {
                    handle_frame(&mut emu, build_id, frame, &mut io)?;
                }
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
            Err(error) => return Err(error.to_string()),
        }
        if emu.is_running() {
            let result = emu.run_batch(50_000);
            flush_uart(&mut emu, &mut io)?;
            if !matches!(result.reason, StopReason::CycleLimit) {
                write_debug(&mut io, stop_payload(&emu, &result.reason))?;
            }
        }
        std::thread::sleep(Duration::from_millis(1));
    }
}

fn handle_frame(
    emu: &mut EmulatorCore,
    build_id: u32,
    frame: Frame,
    io: &mut File,
) -> Result<(), String> {
    match (frame.kind, frame.payload.as_slice()) {
        (HELLO, b"SWT1") => write_frame(io, HELLO_ACK, 0, b"SWT1"),
        (1, bytes) => {
            for &byte in bytes {
                emu.send_uart_byte(byte);
                emu.resume();
                let result = emu.run_batch(20_000);
                if !matches!(result.reason, StopReason::CycleLimit) {
                    write_debug(io, stop_payload(emu, &result.reason))?;
                }
            }
            flush_uart(emu, io)
        }
        (DEBUG_REQUEST, [1]) => write_debug(
            io,
            vec![
                1,
                build_id as u8,
                (build_id >> 8) as u8,
                (build_id >> 16) as u8,
            ],
        ),
        (DEBUG_REQUEST, [2, endpoint]) => {
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
        (DEBUG_REQUEST, [3, a0, a1, a2, length]) => {
            let address = u24(*a0, *a1, *a2);
            let mut response = vec![3, *a0, *a1, *a2];
            response.extend(emu.read_memory(address, u32::from((*length).min(64))));
            write_debug(io, response)
        }
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

fn flush_uart(emu: &mut EmulatorCore, io: &mut File) -> Result<(), String> {
    let bytes = emu.get_uart_output().as_bytes().to_vec();
    if !bytes.is_empty() {
        write_frame(io, 2, 1, &bytes)?;
        emu.clear_uart_output();
    }
    Ok(())
}

fn write_debug(io: &mut File, payload: Vec<u8>) -> Result<(), String> {
    write_frame(io, DEBUG_RESPONSE, 0, &payload)
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
    io.write_all(&bytes).map_err(err)?;
    io.flush().map_err(err)
}

#[derive(Default)]
struct Decoder {
    bytes: Vec<u8>,
}
struct Frame {
    kind: u8,
    payload: Vec<u8>,
}
impl Decoder {
    fn push(&mut self, input: &[u8]) -> Vec<Frame> {
        self.bytes.extend(input);
        let mut frames = Vec::new();
        loop {
            let Some(pos) = self.bytes.windows(2).position(|v| v == SYNC) else {
                self.bytes.clear();
                break;
            };
            self.bytes.drain(..pos);
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
                    payload: self.bytes[7..end - 1].to_vec(),
                });
            }
            self.bytes.drain(..end);
        }
        frames
    }
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
