use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, VecDeque};
use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::fd::{AsRawFd, RawFd};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use te_rs::debug::{DebugConsole, DebugMap, help_lines, identity_request};
use te_rs::protocol::{ConnectionDecoder, Frame, FrameType, Mode, StreamItem, VERSION, hello};
use te_rs::resource::SnapshotAssembler;
use te_rs::ui::{CommandOutcome, Desktop, PaneKind};

const DEFAULT_DEVICE: &str = "/dev/ttyUSB0";
const SYNC_TIMEOUT: Duration = Duration::from_secs(2);
const MAX_MONITOR_RESPONSE: usize = 1024;
const MAX_WINDOWS_SERIAL_BACKLOG: usize = 64 * 1024;

// Keep monitor diagnostics in one place. Replace or extend these placeholders
// when the monitor's exact error messages are known.
const MONITOR_ERROR_PATTERNS: &[&str] = &["invalid", "too long", "bad hex", "unknown command"];

#[derive(Debug, PartialEq)]
struct Options {
    device: String,
    delay: Option<Duration>,
    byte_delay: Option<Duration>,
    sync: bool,
    verbose: bool,
    swtos: bool,
    framed: bool,
    windows: bool,
    prefix: u8,
    debug_map: Option<PathBuf>,
    session: Option<PathBuf>,
    time_mode: Option<TimeMode>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum TimeMode {
    Uptime,
    Clock,
}

/// Which time services currently have a consumer running.
///
/// Both kinds can run at once, and each app advances only on the tick for its
/// own program, so a single active mode is not enough: sending only uptime
/// ticks leaves every spawned clock waiting forever.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
struct TimeModes {
    uptime: bool,
    clock: bool,
}

impl TimeModes {
    fn any(self) -> bool {
        self.uptime || self.clock
    }

    fn active(self) -> impl Iterator<Item = TimeMode> {
        [
            self.uptime.then_some(TimeMode::Uptime),
            self.clock.then_some(TimeMode::Clock),
        ]
        .into_iter()
        .flatten()
    }
}

fn time_mode_for_title(title: &str) -> Option<TimeMode> {
    if title.starts_with("mon") || title.starts_with("upti") {
        Some(TimeMode::Uptime)
    } else if title.starts_with("cloc") {
        Some(TimeMode::Clock)
    } else {
        None
    }
}

fn active_time_modes(
    resources: &SnapshotAssembler,
    channel_modes: &BTreeMap<u8, TimeMode>,
) -> TimeModes {
    TimeModes {
        uptime: resources.has_process_named("upti")
            || resources.has_process_named("mon")
            || channel_modes.values().any(|mode| *mode == TimeMode::Uptime),
        clock: resources.has_process_named("cloc")
            || channel_modes.values().any(|mode| *mode == TimeMode::Clock),
    }
}

#[derive(Deserialize, Serialize)]
struct SavedPane {
    kind: PaneKind,
    channel: u8,
    title: String,
}

#[derive(Deserialize, Serialize)]
struct SavedSession {
    format: String,
    panes: Vec<SavedPane>,
}

fn save_session(path: &Path, desktop: &Desktop) -> io::Result<()> {
    let session = SavedSession {
        format: "swtos-session-v1".into(),
        panes: desktop
            .layout()
            .into_iter()
            .map(|(kind, channel, title)| SavedPane {
                kind,
                channel,
                title,
            })
            .collect(),
    };
    let contents = serde_json::to_string_pretty(&session).map_err(io::Error::other)?;
    fs::write(path, format!("{contents}\n"))
}

fn load_session(path: &Path, desktop: &mut Desktop) -> io::Result<()> {
    let session: SavedSession =
        serde_json::from_str(&fs::read_to_string(path)?).map_err(io::Error::other)?;
    if session.format != "swtos-session-v1" {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "unsupported session format",
        ));
    }
    let panes = session
        .panes
        .into_iter()
        .map(|pane| (pane.kind, pane.channel, pane.title))
        .collect::<Vec<_>>();
    desktop.restore_layout(&panes);
    Ok(())
}

enum ParseResult {
    Run(Options),
    Help,
}

fn help(program: &str) -> String {
    format!(
        "\
Usage: {program} [OPTIONS] [DEVICE]

Interactive COR24 serial terminal and paced .lgo file uploader.

Arguments:
  [DEVICE]              Serial device [default: {DEFAULT_DEVICE}]

Options:
  -d, --delay <MS>      Wait 1 to 10 milliseconds after each uploaded line
  -b, --byte-delay <US> Drain the UART and wait 1 to 10000 microseconds after
                        each uploaded byte
  -s, --sync            Validate each line's exact echo before sending the next
  -v, --verbose         Log serial setup and per-line upload details to stderr
      --swtos           Enable SWTOS menu, Uptime, Clock, echo, and Ctrl-]
      --framed          Negotiate SWTOS multiplexed transport (plain fallback)
      --windows         Open the negotiated dynamic SWTOS desktop
      --prefix <KEY>    Host-command prefix byte or ^X notation [default: ^O]
      --debug-map PATH  Load matching program.debug.json for inspection
      --session PATH    Restore and save a dynamic window layout
      --uptime-active   Reattach while SWTOS is already inside Uptime
      --clock-active    Reattach while SWTOS is already inside Clock
  -h, --help            Print this help

The serial port is configured for 921600 baud, 8 data bits, no parity, one
stop bit, and RTS/CTS flow control. During a session, press Ctrl-R and enter a
filename to upload it. Press Ctrl-C to exit. With --sync, each line must be
echoed exactly within 2 seconds; a mismatch or timeout aborts the upload.
"
    )
}

fn parse_args<I>(args: I) -> Result<ParseResult, String>
where
    I: IntoIterator<Item = String>,
{
    let mut args = args.into_iter();
    let _program = args.next();
    let mut options = Options {
        device: DEFAULT_DEVICE.into(),
        delay: None,
        byte_delay: None,
        sync: false,
        verbose: false,
        swtos: false,
        framed: false,
        windows: false,
        prefix: 0x0f,
        debug_map: None,
        session: None,
        time_mode: None,
    };
    let mut device_seen = false;

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "-h" | "--help" => return Ok(ParseResult::Help),
            "-v" | "--verbose" => options.verbose = true,
            "--swtos" => options.swtos = true,
            "--framed" => {
                options.swtos = true;
                options.framed = true;
            }
            "--windows" => {
                options.swtos = true;
                options.framed = true;
                options.windows = true;
            }
            "--prefix" => {
                let value = args
                    .next()
                    .ok_or_else(|| "--prefix requires a value".to_string())?;
                options.prefix = parse_prefix(&value)?;
            }
            "--debug-map" => {
                options.debug_map = Some(PathBuf::from(
                    args.next()
                        .ok_or_else(|| "--debug-map requires a path".to_string())?,
                ));
            }
            "--session" => {
                options.session = Some(PathBuf::from(
                    args.next()
                        .ok_or_else(|| "--session requires a path".to_string())?,
                ));
            }
            "--uptime-active" => {
                options.swtos = true;
                options.time_mode = Some(TimeMode::Uptime);
            }
            "--clock-active" => {
                options.swtos = true;
                options.time_mode = Some(TimeMode::Clock);
            }
            "-s" | "--sync" => options.sync = true,
            "-d" | "--delay" => {
                let value = args
                    .next()
                    .ok_or_else(|| format!("{arg} requires a value in milliseconds"))?;
                let milliseconds: u64 = value.parse().map_err(|_| {
                    format!("invalid delay '{value}': expected an integer from 1 to 10")
                })?;
                if !(1..=10).contains(&milliseconds) {
                    return Err(format!(
                        "invalid delay '{value}': expected an integer from 1 to 10"
                    ));
                }
                options.delay = Some(Duration::from_millis(milliseconds));
            }
            "-b" | "--byte-delay" => {
                let value = args
                    .next()
                    .ok_or_else(|| format!("{arg} requires a value in microseconds"))?;
                let microseconds: u64 = value.parse().map_err(|_| {
                    format!("invalid byte delay '{value}': expected an integer from 1 to 10000")
                })?;
                if !(1..=10_000).contains(&microseconds) {
                    return Err(format!(
                        "invalid byte delay '{value}': expected an integer from 1 to 10000"
                    ));
                }
                options.byte_delay = Some(Duration::from_micros(microseconds));
            }
            _ if arg.starts_with('-') => return Err(format!("unknown option '{arg}'")),
            _ if !device_seen => {
                options.device = arg;
                device_seen = true;
            }
            _ => return Err(format!("unexpected argument '{arg}'")),
        }
    }

    Ok(ParseResult::Run(options))
}

/// Spell a prefix byte the way a person would say it.
fn prefix_label(prefix: u8) -> String {
    match prefix {
        0x00..=0x1f => format!("Ctrl-{}", (prefix + b'@') as char),
        byte => format!("{:?}", byte as char),
    }
}

fn parse_prefix(value: &str) -> Result<u8, String> {
    let bytes = value.as_bytes();
    match bytes {
        [byte] => Ok(*byte),
        [b'^', letter @ b'@'..=b'_'] => Ok(*letter & 0x1f),
        _ => Err(format!("invalid prefix '{value}': expected one byte or ^X")),
    }
}

/// 921,600 baud, the COR24-TB UART rate.
///
/// Linux encodes speeds as opaque `Bxxx` indices, so the constant must come
/// from libc. Darwin and the BSDs encode `speed_t` as the literal baud rate
/// and define no `B921600`, so the numeric value is used directly there.
#[cfg(target_os = "linux")]
const SERIAL_SPEED: libc::speed_t = libc::B921600;
#[cfg(not(target_os = "linux"))]
const SERIAL_SPEED: libc::speed_t = 921_600;

struct TermiosGuard {
    fd: RawFd,
    original: libc::termios,
}

impl TermiosGuard {
    fn serial(fd: RawFd) -> io::Result<Self> {
        let original = get_termios(fd)?;
        let mut configured = original;
        // SAFETY: configured points to a valid termios structure.
        unsafe { libc::cfmakeraw(&mut configured) };
        configured.c_cflag &= !(libc::PARENB | libc::CSTOPB | libc::CSIZE);
        configured.c_cflag |= libc::CS8 | libc::CLOCAL | libc::CREAD | libc::CRTSCTS;
        configured.c_iflag |= libc::IGNBRK;

        // SAFETY: configured is valid and SERIAL_SPEED is a supported speed
        // for this platform. Errors are reported through errno.
        if unsafe { libc::cfsetispeed(&mut configured, SERIAL_SPEED) } == -1
            || unsafe { libc::cfsetospeed(&mut configured, SERIAL_SPEED) } == -1
        {
            return Err(io::Error::last_os_error());
        }
        set_termios(fd, &configured)?;
        let modem_bits: libc::c_int = libc::TIOCM_RTS;
        // Match the proven Python terminal: explicitly assert the FTDI RTS
        // output after enabling hardware flow control.
        if unsafe { libc::ioctl(fd, libc::TIOCMBIS, &modem_bits) } == -1 {
            let error = io::Error::last_os_error();
            // PTYs used by the acceptance harness have termios but no modem
            // control lines. Real serial-device ioctl failures remain fatal.
            if !matches!(
                error.raw_os_error(),
                Some(libc::ENOTTY) | Some(libc::EINVAL)
            ) {
                return Err(error);
            }
        }
        Ok(Self { fd, original })
    }

    fn terminal(fd: RawFd) -> io::Result<Self> {
        let original = get_termios(fd)?;
        let configured = terminal_attributes(original);
        set_termios(fd, &configured)?;
        Ok(Self { fd, original })
    }
}

fn terminal_attributes(mut attributes: libc::termios) -> libc::termios {
    // Raw mode makes Ctrl-R and Ctrl-C available to this process as bytes.
    // SAFETY: attributes points to a valid termios structure.
    unsafe { libc::cfmakeraw(&mut attributes) };
    // Keep terminal output readable: the COR24 sends LF line endings, so
    // translate each LF to CRLF instead of letting successive lines stair-step.
    attributes.c_oflag |= libc::OPOST | libc::ONLCR;
    attributes
}

impl Drop for TermiosGuard {
    fn drop(&mut self) {
        // Best-effort restoration during normal exit and error unwinding.
        let _ = set_termios(self.fd, &self.original);
    }
}

struct AlternateScreenGuard {
    fd: RawFd,
}

impl AlternateScreenGuard {
    fn enter(tty: &mut File) -> io::Result<Self> {
        tty.write_all(b"\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H")?;
        tty.flush()?;
        Ok(Self {
            fd: tty.as_raw_fd(),
        })
    }
}

impl Drop for AlternateScreenGuard {
    fn drop(&mut self) {
        let restore = b"\x1b[?25h\x1b[?1049l";
        // SAFETY: fd remains owned by the surrounding File until this guard
        // drops; restoration is best effort during both success and unwind.
        unsafe {
            libc::write(self.fd, restore.as_ptr().cast(), restore.len());
        }
    }
}

fn get_termios(fd: RawFd) -> io::Result<libc::termios> {
    // SAFETY: zero is a valid initial bit pattern and tcgetattr initializes it.
    let mut attributes = unsafe { std::mem::zeroed() };
    // SAFETY: attributes is writable and fd is expected to refer to a tty.
    if unsafe { libc::tcgetattr(fd, &mut attributes) } == -1 {
        Err(io::Error::last_os_error())
    } else {
        Ok(attributes)
    }
}

fn set_termios(fd: RawFd, attributes: &libc::termios) -> io::Result<()> {
    // SAFETY: attributes points to a valid termios structure.
    if unsafe { libc::tcsetattr(fd, libc::TCSANOW, attributes) } == -1 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

fn set_nonblocking(fd: RawFd) -> io::Result<()> {
    // SAFETY: F_GETFL/F_SETFL operate on the live serial descriptor.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags == -1 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } == -1 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

fn queue_serial(output: &mut VecDeque<u8>, bytes: &[u8]) -> bool {
    if output.len().saturating_add(bytes.len()) > MAX_WINDOWS_SERIAL_BACKLOG {
        return false;
    }
    output.extend(bytes.iter().copied());
    true
}

fn flush_serial(serial: &mut File, output: &mut VecDeque<u8>) -> io::Result<()> {
    while !output.is_empty() {
        let (front, _) = output.as_slices();
        match serial.write(front) {
            Ok(0) => break,
            Ok(count) => {
                output.drain(..count);
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

fn terminal_size(fd: RawFd) -> (usize, usize) {
    // SAFETY: winsize is initialized before its fields are read and fd is a tty.
    let mut size: libc::winsize = unsafe { std::mem::zeroed() };
    if unsafe { libc::ioctl(fd, libc::TIOCGWINSZ, &mut size) } == 0 {
        (
            usize::from(size.ws_col).max(24),
            usize::from(size.ws_row).max(8),
        )
    } else {
        (80, 24)
    }
}

fn prompt_for_file(tty: &mut File) -> io::Result<Option<String>> {
    tty.write_all(b"\r\nfile: ")?;
    tty.flush()?;
    let mut name = Vec::new();
    let mut byte = [0_u8; 1];

    loop {
        tty.read_exact(&mut byte)?;
        match byte[0] {
            b'\r' | b'\n' => {
                tty.write_all(b"\r\n")?;
                tty.flush()?;
                break;
            }
            0x03 => return Ok(None),
            0x08 | 0x7f if !name.is_empty() => {
                name.pop();
                tty.write_all(b"\x08 \x08")?;
                tty.flush()?;
            }
            0x08 | 0x7f => {}
            value => {
                name.push(value);
                tty.write_all(&[value])?;
                tty.flush()?;
            }
        }
    }

    Ok(Some(String::from_utf8_lossy(&name).into_owned()))
}

fn monitor_error(response: &[u8]) -> Option<&'static str> {
    let lowercase = String::from_utf8_lossy(response).to_ascii_lowercase();
    MONITOR_ERROR_PATTERNS
        .iter()
        .copied()
        .find(|pattern| lowercase.contains(pattern))
}

fn read_monitor_response_line(
    serial: &mut File,
    tty: &mut File,
    response: &mut Vec<u8>,
    deadline: Instant,
) -> io::Result<()> {
    let mut byte = [0_u8; 1];
    while response.len() < MAX_MONITOR_RESPONSE && !response.ends_with(b"\n") {
        let now = Instant::now();
        if now >= deadline {
            break;
        }
        let remaining = deadline.saturating_duration_since(now);
        let timeout_ms = remaining.as_millis().min(i32::MAX as u128) as i32;
        let [ready] = match wait_readable([serial.as_raw_fd()], timeout_ms) {
            Ok(readable) => readable,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        };
        if !ready {
            break;
        }
        serial.read_exact(&mut byte)?;
        tty.write_all(&byte)?;
        tty.flush()?;
        response.push(byte[0]);
        if monitor_error(response).is_some() {
            break;
        }
    }
    Ok(())
}

fn receive_echo(
    serial: &mut File,
    tty: &mut File,
    expected: &[u8],
    validate: bool,
) -> io::Result<()> {
    let deadline = Instant::now() + SYNC_TIMEOUT;
    let mut received = Vec::with_capacity(expected.len());
    let mut byte = [0_u8; 1];

    while received.len() < expected.len() {
        let now = Instant::now();
        if now >= deadline {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                format!(
                    "echo timeout after {} of {} bytes",
                    received.len(),
                    expected.len()
                ),
            ));
        }
        let remaining = deadline.saturating_duration_since(now);
        let timeout_ms = remaining.as_millis().min(i32::MAX as u128) as i32;
        let [ready] = match wait_readable([serial.as_raw_fd()], timeout_ms) {
            Ok(readable) => readable,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        };
        if !ready {
            continue;
        }

        serial.read_exact(&mut byte)?;
        tty.write_all(&byte)?;
        tty.flush()?;
        let index = received.len();
        received.push(byte[0]);
        if validate && byte[0] != expected[index] {
            read_monitor_response_line(serial, tty, &mut received, deadline)?;
            if let Some(pattern) = monitor_error(&received) {
                let message = String::from_utf8_lossy(&received);
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!(
                        "monitor rejected input (matched '{pattern}'): {}",
                        message.trim()
                    ),
                ));
            }
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "echo mismatch at byte {}: sent 0x{:02x}, received 0x{:02x}",
                    index + 1,
                    expected[index],
                    byte[0]
                ),
            ));
        }
    }
    Ok(())
}

fn drain_serial(fd: RawFd) -> io::Result<()> {
    loop {
        // SAFETY: fd refers to the open serial tty. tcdrain waits until all
        // queued output has physically transmitted.
        if unsafe { libc::tcdrain(fd) } == 0 {
            return Ok(());
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

fn upload(path: &Path, serial: &mut File, tty: &mut File, options: &Options) -> io::Result<()> {
    let file = File::open(path)?;
    let mut reader = BufReader::new(file);
    let mut line = Vec::new();
    let mut line_number = 0_usize;

    loop {
        line.clear();
        if reader.read_until(b'\n', &mut line)? == 0 {
            break;
        }
        line_number += 1;
        if options.verbose {
            eprintln!(
                "upload: line {line_number}, {} bytes{}",
                line.len(),
                if options.sync {
                    ", validating echo"
                } else {
                    ", draining echo"
                }
            );
        }

        if let Some(byte_delay) = options.byte_delay {
            for byte in &line {
                serial.write_all(std::slice::from_ref(byte))?;
                drain_serial(serial.as_raw_fd())?;
                thread::sleep(byte_delay);
            }
        } else {
            serial.write_all(&line)?;
            serial.flush()?;
        }
        // The monitor echoes every record. Always consume that echo so the
        // host receive queue cannot fill, deassert RTS, and deadlock hardware
        // flow control. --sync additionally validates every echoed byte.
        receive_echo(serial, tty, &line, options.sync).map_err(|error| {
            io::Error::new(error.kind(), format!("line {line_number}: {error}"))
        })?;
        if let Some(delay) = options.delay {
            thread::sleep(delay);
        }
    }

    if options.verbose {
        eprintln!(
            "upload: completed {line_number} lines from {}",
            path.display()
        );
    }
    Ok(())
}

fn time_frame(mode: TimeMode, tick: u32) -> Vec<u8> {
    let mut frame = vec![0xff, if mode == TimeMode::Uptime { 1 } else { 2 }];
    for byte in [tick as u8, (tick >> 8) as u8, (tick >> 16) as u8] {
        match byte {
            0xff => frame.extend_from_slice(&[0xff, 0]),
            0x1d => frame.extend_from_slice(&[0xff, 3]),
            _ => frame.push(byte),
        }
    }
    frame
}

/// Ask the target to restart its shell.
///
/// These two bytes are read by the target's UART interrupt handler, not by
/// anything downstream of it, because this exists for the case where nothing
/// on the target is reading input any more: a command running in the shell's
/// own context that will not give the CPU back. The handler is then the only
/// code still running, and this is the one thing it listens for.
const SHELL_RESTART: [u8; 2] = [0xff, 4];
const SYSTEM_REBOOT: [u8; 2] = [0xff, 5];

/// The adapter's passthrough frame type, which is not one of the protocol's
/// own: it asks for its payload to be put on the target's UART verbatim.
const PASSTHROUGH: u8 = 0xfe;

/// Wrap bytes so they survive the debug adapter.
///
/// Written raw they do not: once the link is framed the adapter reads frames,
/// and anything that is not one is discarded before it reaches the target.
fn passthrough_frame(payload: &[u8]) -> Vec<u8> {
    let length = payload.len() as u16;
    let mut bytes = vec![VERSION, PASSTHROUGH, 0, length as u8, (length >> 8) as u8];
    bytes.extend_from_slice(payload);
    let sum = bytes.iter().fold(0_u8, |sum, byte| sum.wrapping_add(*byte));
    let mut framed = vec![0xa5, 0x5a];
    framed.append(&mut bytes);
    framed.push(sum);
    framed
}

/// The restart request, addressed to whatever is on the other end of the link.
fn shell_restart_request(mode: Mode) -> Vec<u8> {
    match mode {
        Mode::Framed => passthrough_frame(&SHELL_RESTART),
        Mode::Plain => SHELL_RESTART.to_vec(),
    }
}

fn system_reboot_request(mode: Mode) -> Vec<u8> {
    match mode {
        Mode::Framed => passthrough_frame(&SYSTEM_REBOOT),
        Mode::Plain => SYSTEM_REBOOT.to_vec(),
    }
}

fn scheduler_heartbeat(tick: u32) -> [u8; 5] {
    [0xff, 1, tick as u8, (tick >> 8) as u8, (tick >> 16) as u8]
}

/// Realign the target's heartbeat parser and return whatever it had already
/// sent.
///
/// The bytes waiting here are the target's own output from before this
/// frontend attached. On a reconnect they belong to the previous decoder
/// generation and the caller discards them. On a first attach they are the
/// boot banner and the shell's opening menu, and discarding them left the
/// Shell pane blank until the operator pressed a key -- which the menu then
/// rejected as an invalid choice. Hand them back and let each caller decide.
fn resynchronize_heartbeat_parser(serial: &mut File) -> io::Result<Vec<u8>> {
    // A detached frontend may leave the target ISR expecting one of the three
    // timestamp bytes. The first complete frame drains that partial state;
    // the second is then aligned. Any ordinary leftovers are harmless because
    // the SWT frame decoder searches for its A5 5A sync before HELLO.
    for _ in 0..2 {
        serial.write_all(&scheduler_heartbeat(0))?;
        serial.flush()?;
        thread::sleep(Duration::from_millis(10));
    }
    // Frames already in flight belong to the previous decoder generation.
    // Quarantine them before HELLO so they cannot be rendered as plain text.
    let mut stale = [0_u8; 1024];
    let mut pending = Vec::new();
    loop {
        // The serial descriptor deliberately remains blocking for normal I/O.
        // Probe it first so an empty reconnect quarantine cannot stall HELLO.
        let [ready] = match wait_readable([serial.as_raw_fd()], 0) {
            Ok(readable) => readable,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        };
        if !ready {
            break;
        }
        match serial.read(&mut stale) {
            Ok(0) => break,
            Ok(count) => {
                pending.extend_from_slice(&stale[..count]);
                continue;
            }
            Err(error) => return Err(error),
        }
    }
    Ok(pending)
}

fn multiplexed_time_frame(mode: TimeMode, tick: u32) -> Vec<u8> {
    Frame {
        kind: match mode {
            TimeMode::Uptime => FrameType::Uptime,
            TimeMode::Clock => FrameType::WallClock,
        },
        channel: 0,
        payload: vec![tick as u8, (tick >> 8) as u8, (tick >> 16) as u8],
    }
    .encode()
    .expect("three-byte time payload is within the protocol limit")
}

fn multiplexed_input_frame(channel: u8, payload: &[u8]) -> Vec<u8> {
    Frame {
        kind: FrameType::TtyInput,
        channel,
        payload: payload.to_vec(),
    }
    .encode()
    .expect("terminal input payload is within the protocol limit")
}

fn resource_request_frame() -> Vec<u8> {
    Frame {
        kind: FrameType::ResourceSnapshot,
        channel: 0,
        payload: Vec::new(),
    }
    .encode()
    .expect("empty resource request is bounded")
}

fn debug_request_frame(payload: Vec<u8>) -> Vec<u8> {
    Frame {
        kind: FrameType::DebugRequest,
        channel: 0,
        payload,
    }
    .encode()
    .expect("debug request payload is bounded")
}

fn wall_centiseconds() -> u32 {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let raw = now.as_secs() as libc::time_t;
    // SAFETY: localtime_r initializes the supplied tm from a valid time_t.
    let mut local: libc::tm = unsafe { std::mem::zeroed() };
    unsafe { libc::localtime_r(&raw, &mut local) };
    ((local.tm_hour * 3600 + local.tm_min * 60 + local.tm_sec) as u32) * 100
        + now.subsec_millis() / 10
}

fn echo_swtos_key(tty: &mut File, byte: u8) -> io::Result<()> {
    match byte {
        b'\r' | b'\n' => tty.write_all(b"\r\n"),
        0x1b | 0x1d => tty.write_all(b"Escape\r\n"),
        0x08 | 0x7f => tty.write_all(b"\x08 \x08"),
        0x20..=0x7e => tty.write_all(&[byte]),
        _ => Ok(()),
    }
}

/// Recognize a request to kill endpoint 1, in the spellings the shell accepts.
fn is_shell_restart_request(command: &str) -> bool {
    let mut words = command.split_whitespace();
    if words.next() != Some("kill") {
        return false;
    }
    let target = words.next().map(|word| word.trim_start_matches("ep="));
    words.next().is_none() && target == Some("1")
}

fn is_numeric_menu_choice(byte: u8) -> bool {
    matches!(byte, b'1'..=b'5')
}

/// Put the debugger's own help in its pane.
///
/// Shown when the session opens and again whenever the target says it has
/// been rewound, because a restart or a reboot is exactly the moment someone
/// is looking for a way out and has nothing else on screen to go on.
fn show_debugger_help(desktop: &mut Desktop) {
    for line in help_lines() {
        desktop.push_channel(254, format!("{line}\n").as_bytes());
    }
    debugger_prompt(desktop);
}

/// Mark where debugger input goes.
///
/// The pane is titled, so it never needed a line announcing itself; what it
/// needed was somewhere the typing visibly starts.
fn debugger_prompt(desktop: &mut Desktop) {
    desktop.push_channel(254, b"(dbg) ");
}

/// The target announces its own rewinds. These are the two it prints.
///
/// Read from the shell's output rather than from what this frontend sent,
/// because a rewind can be asked for in ways this frontend never sees: kill 1
/// or reboot typed at the prompt, or the escape sent by another tool.
const REWIND_BANNERS: [&str; 2] = ["SHELL RESTARTED", "SYSTEM REBOOTED"];

fn desktop_clock() -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let raw = now.as_secs() as libc::time_t;
    // SAFETY: localtime_r initializes local from a valid time_t.
    let mut local: libc::tm = unsafe { std::mem::zeroed() };
    unsafe { libc::localtime_r(&raw, &mut local) };
    format!(
        "{:02}:{:02}:{:02}",
        local.tm_hour, local.tm_min, local.tm_sec
    )
}

fn repaint_desktop(tty: &mut File, desktop: &mut Desktop) -> io::Result<(usize, usize)> {
    let size = terminal_size(tty.as_raw_fd());
    desktop.set_clock(desktop_clock());
    tty.write_all(desktop.render(size.0, size.1).as_bytes())?;
    tty.flush()?;
    Ok(size)
}

fn handle_copy_input(desktop: &mut Desktop, byte: u8, escape_state: &mut u8) {
    match (*escape_state, byte) {
        (0, 0x1b) => *escape_state = 1,
        (1, b'[') => *escape_state = 2,
        (2, b'A') => {
            desktop.copy_move(1, 0);
            *escape_state = 0;
        }
        (2, b'B') => {
            desktop.copy_move(-1, 0);
            *escape_state = 0;
        }
        (2, b'C') => {
            desktop.copy_move(0, 1);
            *escape_state = 0;
        }
        (2, b'D') => {
            desktop.copy_move(0, -1);
            *escape_state = 0;
        }
        (2, b'5') => *escape_state = 5,
        (2, b'6') => *escape_state = 6,
        (5, b'~') => {
            desktop.copy_move(10, 0);
            *escape_state = 0;
        }
        (6, b'~') => {
            desktop.copy_move(-10, 0);
            *escape_state = 0;
        }
        (0, b'k') => desktop.copy_move(1, 0),
        (0, b'j') => desktop.copy_move(-1, 0),
        (0, b'h') => desktop.copy_move(0, -1),
        (0, b'l') => desktop.copy_move(0, 1),
        (0, b'u') => desktop.copy_move(10, 0),
        (0, b'd') => desktop.copy_move(-10, 0),
        (0, b'g') => desktop.copy_home(),
        (0, b'G') => desktop.copy_end(),
        (0, b'q') => {
            desktop.command(b'y');
        }
        _ => *escape_state = 0,
    }
}

/// Wait until at least one of the descriptors is readable, reporting
/// readiness per descriptor.
///
/// `select` is used rather than `poll` because Darwin reports `POLLNVAL` for
/// a perfectly valid `/dev/tty` descriptor instead of `POLLIN`, which
/// silently swallows every keystroke. `select` reports the controlling
/// terminal correctly on both Darwin and Linux.
///
/// A negative `timeout_ms` waits indefinitely. A hangup surfaces as
/// readability whose subsequent read returns zero bytes or fails, which each
/// caller already treats as a lost transport.
fn wait_readable<const N: usize>(fds: [RawFd; N], timeout_ms: i32) -> io::Result<[bool; N]> {
    // SAFETY: an all-zero fd_set is the empty set on every supported platform.
    let mut readable: libc::fd_set = unsafe { std::mem::zeroed() };
    let mut highest = 0;
    for &fd in &fds {
        // SAFETY: readable is a valid fd_set and fd is an open descriptor
        // below FD_SETSIZE.
        unsafe { libc::FD_SET(fd, &mut readable) };
        highest = highest.max(fd);
    }
    let mut timeout = libc::timeval {
        tv_sec: (timeout_ms / 1000) as libc::time_t,
        tv_usec: ((timeout_ms % 1000) * 1000) as libc::suseconds_t,
    };
    let deadline = if timeout_ms < 0 {
        std::ptr::null_mut()
    } else {
        &mut timeout
    };
    // SAFETY: readable is a valid fd_set and deadline is null or a valid timeval.
    let ready = unsafe {
        libc::select(
            highest + 1,
            &mut readable,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            deadline,
        )
    };
    if ready == -1 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: readable is a valid fd_set and each fd is an open descriptor.
    Ok(fds.map(|fd| unsafe { libc::FD_ISSET(fd, &readable) }))
}

/// Shown in a pane when Escape is sent to the target.
///
/// Escape is not printable, so the local echo skipped it and the key looked
/// dead: nothing appeared, and an application that exits on Escape only
/// answered afterwards. Naming it makes the keystroke visible at the point it
/// was sent, whichever way it was typed.
const ESCAPE_ECHO: &[u8] = b"Esc";

/// Write what was known about the link when it was lost.
///
/// The frontend owns the alternate screen, so anything printed here is the
/// operator's only record; the launcher captures it into the session log.
/// Without it a lost transport reports a bare errno, or the generic phrase
/// standing in for a cause that was thrown away.
fn report_transport_loss(
    detail: &str,
    connection: &ConnectionDecoder,
    resources: &SnapshotAssembler,
    connected: Instant,
) {
    eprintln!(
        "transport lost after {:.1}s: {detail}",
        connected.elapsed().as_secs_f32()
    );
    eprintln!("  negotiated mode: {:?}", connection.mode());
    match resources.snapshot() {
        Some(snapshot) => eprintln!(
            "  last snapshot: generation {} uart rx={} tx={} protocol-errors={} slots={}/{}",
            snapshot.generation,
            snapshot.uart_rx,
            snapshot.uart_tx,
            snapshot.protocol_errors,
            snapshot.memory.used_slots,
            snapshot.memory.total_slots
        ),
        None => eprintln!("  last snapshot: none received"),
    }
}

fn run_windows(options: &Options) -> io::Result<()> {
    let connected = Instant::now();
    let mut serial = OpenOptions::new()
        .read(true)
        .write(true)
        .open(&options.device)?;
    let mut tty = OpenOptions::new().read(true).write(true).open("/dev/tty")?;
    let _serial_guard = TermiosGuard::serial(serial.as_raw_fd())?;
    let _tty_guard = TermiosGuard::terminal(tty.as_raw_fd())?;
    let _screen_guard = AlternateScreenGuard::enter(&mut tty)?;
    let mut connection = ConnectionDecoder::default();
    let mut resources = SnapshotAssembler::default();
    let (debug_map, debug_map_error) = match options.debug_map.as_deref() {
        Some(path) => match DebugMap::load(path) {
            Ok(map) => (Some(map), None),
            Err(error) => (None, Some(error)),
        },
        None => (None, None),
    };
    let mut debugger = DebugConsole::new(debug_map);
    let mut debug_input = String::new();
    let mut debug_identity_sent = false;
    let mut transport_decode_error = false;
    let mut desktop = Desktop::default();
    if let Some(path) = options.session.as_deref()
        && path.exists()
        && let Err(error) = load_session(path, &mut desktop)
    {
        desktop.set_error(Some(format!("session: {error}")));
    }
    desktop.set_prefix_label(prefix_label(options.prefix));
    show_debugger_help(&mut desktop);
    if let Some(error) = debug_map_error {
        desktop.push_channel(254, format!("{error}\n").as_bytes());
    }
    // A prompt is owed after a reply, not after the command that asked for it:
    // the target answers asynchronously and in as many frames as it likes, so
    // printing one straight after the command put the reply on top of it and
    // left the next line typed with no prompt at all. Wait for the frames to
    // stop arriving.
    let mut debugger_prompt_due: Option<Instant> = None;
    let mut prefix_pending = false;
    let mut copy_escape_state = 0;
    let mut shell_input = String::new();
    let mut last_size = repaint_desktop(&mut tty, &mut desktop)?;
    let mut serial_buffer = [0_u8; 1024];
    let mut tty_buffer = [0_u8; 256];
    let mut next_resource_request = Instant::now();
    let mut next_scheduler_heartbeat = Instant::now();
    let mut next_hello_retry = Instant::now() + Duration::from_millis(250);
    //: Characters still to type on the shell's behalf, one per pass. A burst
    //: overruns the target's input ring and is dropped without trace; this
    //: loop's own cadence is the pacing a person would have provided.
    let mut injected: Vec<u8> = Vec::new();
    let mut next_time_frames = Instant::now();
    let mut next_footer_repaint = Instant::now();
    let mut time_modes = TimeModes::default();
    // Channel-open/title notifications are small and arrive before a complete
    // multi-record resource snapshot on reattach. Use them to start clocks
    // immediately; completed snapshots still reconcile the authoritative
    // process set below.
    let mut channel_time_modes = BTreeMap::new();

    // Nothing precedes this frontend on a first attach, so the target's boot
    // output is not stale: render it instead of dropping it.
    let pending = resynchronize_heartbeat_parser(&mut serial)?;
    for item in connection.push(&pending) {
        if let StreamItem::Plain(bytes) = item {
            desktop.push_channel(0, &bytes);
        }
    }
    if !pending.is_empty() {
        last_size = repaint_desktop(&mut tty, &mut desktop)?;
    }
    serial.write_all(&hello().encode().expect("HELLO payload is bounded"))?;
    serial.flush()?;
    set_nonblocking(serial.as_raw_fd())?;
    let mut serial_output = VecDeque::new();

    loop {
        flush_serial(&mut serial, &mut serial_output)?;
        // A short timeout provides portable resize detection without installing
        // a process-global signal handler.
        let readable = match wait_readable([serial.as_raw_fd(), tty.as_raw_fd()], 10) {
            Ok(readable) => readable,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        };
        let mut dirty = false;

        if readable[0] {
            let count = match serial.read(&mut serial_buffer) {
                Ok(count) => count,
                // Transient. A descriptor can be reported readable and still
                // have nothing to give, which Darwin does on pseudo-terminals.
                // Retrying is correct; treating it as a hangup ends a healthy
                // session, which is what collapsing every error into a lost
                // transport used to do.
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::Interrupted | io::ErrorKind::WouldBlock
                    ) =>
                {
                    continue;
                }
                Err(error) => {
                    let detail = format!("serial read failed: {error}");
                    desktop.set_connected(false);
                    desktop.set_error(Some(detail.clone()));
                    repaint_desktop(&mut tty, &mut desktop)?;
                    report_transport_loss(&detail, &connection, &resources, connected);
                    return Err(io::Error::new(io::ErrorKind::UnexpectedEof, detail));
                }
            };
            if count == 0 {
                let detail = "serial transport closed: read returned zero".to_string();
                desktop.set_connected(false);
                desktop.set_error(Some(detail.clone()));
                repaint_desktop(&mut tty, &mut desktop)?;
                report_transport_loss(&detail, &connection, &resources, connected);
                return Err(io::Error::new(io::ErrorKind::UnexpectedEof, detail));
            }
            for item in connection.push(&serial_buffer[..count]) {
                if matches!(&item, StreamItem::Frame(_)) && transport_decode_error {
                    desktop.set_error(None);
                    transport_decode_error = false;
                }
                match item {
                    StreamItem::Plain(bytes) => desktop.push_channel(0, &bytes),
                    StreamItem::Frame(frame) if frame.kind == FrameType::TtyOutput => {
                        if !desktop.has_channel(frame.channel) {
                            desktop
                                .add_application(frame.channel, format!("TTY {}", frame.channel));
                        }
                        let rewound = frame.channel == 0 && {
                            let text = String::from_utf8_lossy(&frame.payload);
                            REWIND_BANNERS.iter().any(|banner| text.contains(banner))
                        };
                        desktop.push_channel(frame.channel, &frame.payload);
                        if rewound {
                            show_debugger_help(&mut desktop);
                        }
                    }
                    StreamItem::Frame(frame) if frame.kind == FrameType::ChannelOpen => {
                        let title = String::from_utf8_lossy(&frame.payload).into_owned();
                        if let Some(mode) = time_mode_for_title(&title) {
                            channel_time_modes.insert(frame.channel, mode);
                        } else {
                            channel_time_modes.remove(&frame.channel);
                        }
                        time_modes = active_time_modes(&resources, &channel_time_modes);
                        // A channel is reused when a slot is: start the new
                        // program's pane empty rather than under whatever the
                        // last one left there.
                        desktop.clear_channel(frame.channel);
                        desktop.add_application(
                            frame.channel,
                            if title.is_empty() {
                                format!("TTY {}", frame.channel)
                            } else {
                                title
                            },
                        );
                    }
                    StreamItem::Frame(frame) if frame.kind == FrameType::ChannelClose => {
                        channel_time_modes.remove(&frame.channel);
                        time_modes = active_time_modes(&resources, &channel_time_modes);
                        desktop.release_channel(frame.channel);
                    }
                    StreamItem::Frame(frame) if frame.kind == FrameType::ChannelTitle => {
                        let title = String::from_utf8_lossy(&frame.payload).into_owned();
                        if let Some(mode) = time_mode_for_title(&title) {
                            channel_time_modes.insert(frame.channel, mode);
                        } else {
                            channel_time_modes.remove(&frame.channel);
                        }
                        time_modes = active_time_modes(&resources, &channel_time_modes);
                        desktop.set_channel_title(frame.channel, title);
                    }
                    StreamItem::Frame(frame) if frame.kind == FrameType::ProtocolError => {
                        desktop
                            .set_error(Some(String::from_utf8_lossy(&frame.payload).into_owned()));
                    }
                    StreamItem::Frame(frame) if frame.kind == FrameType::ResourceSnapshot => {
                        if resources.push(&frame.payload, Instant::now()) {
                            // The monitor refreshes on the uptime tick, so it
                            // needs that tick sent even when no uptime is
                            // running. Channel notifications cover the window
                            // before this complete snapshot arrives.
                            time_modes = active_time_modes(&resources, &channel_time_modes);
                            // Channel N carries endpoint N+1, so this is what
                            // teaches a pane the name of the program on it,
                            // and what tells a pane its process has gone.
                            if let Some(snapshot) = resources.snapshot() {
                                let mut live = Vec::new();
                                for process in snapshot.processes.values() {
                                    if process.endpoint > 0 && process.state != 0 {
                                        desktop.name_channel(process.endpoint - 1, &process.name);
                                        live.push(process.endpoint);
                                    }
                                }
                                desktop.mark_live_endpoints(&live);
                            }
                        }
                    }
                    StreamItem::Frame(frame) if frame.kind == FrameType::DebugResponse => {
                        for line in debugger.response(&frame.payload) {
                            desktop.push_channel(254, format!("{line}\n").as_bytes());
                        }
                        debugger_prompt_due = Some(Instant::now() + Duration::from_millis(150));
                    }
                    StreamItem::Frame(_) => {}
                    StreamItem::Error(error) => {
                        transport_decode_error = true;
                        desktop.set_error(Some(format!("{error:?}")));
                    }
                }
            }
            dirty = true;
        }

        if readable[1] {
            let count = tty.read(&mut tty_buffer)?;
            if count == 0 {
                return Ok(());
            }
            for &byte in &tty_buffer[..count] {
                if prefix_pending {
                    prefix_pending = false;
                    match byte {
                        b's' => {
                            let used = desktop
                                .layout()
                                .into_iter()
                                .map(|(_, channel, _)| channel)
                                .collect::<Vec<_>>();
                            if let Some(channel) = (2..=253).find(|channel| !used.contains(channel))
                            {
                                desktop.add_application(channel, format!("TTY {channel}"));
                            }
                        }
                        b'a' => {
                            let used = desktop
                                .layout()
                                .into_iter()
                                .map(|(_, channel, _)| channel)
                                .collect::<Vec<_>>();
                            if let Some(channel) = (1..=253).find(|channel| !used.contains(channel))
                            {
                                desktop.assign_focused(channel, format!("TTY {channel}"));
                            }
                        }
                        b'R' => {
                            if let Some(path) = options.session.as_deref()
                                && let Err(error) = load_session(path, &mut desktop)
                            {
                                desktop.set_error(Some(format!("session: {error}")));
                            }
                        }
                        b'r' => {
                            let renegotiate = connection.mode() == Mode::Plain;
                            if renegotiate {
                                connection.resynchronize();
                                // Realign a possibly partial target heartbeat without
                                // performing a blocking read or write. The Windows
                                // frontend must retain local control even when CTS is
                                // deasserted or the target has stopped consuming bytes.
                                queue_serial(&mut serial_output, &scheduler_heartbeat(0));
                                queue_serial(&mut serial_output, &scheduler_heartbeat(0));
                            }
                            resources = SnapshotAssembler::default();
                            debug_identity_sent = false;
                            transport_decode_error = false;
                            desktop.set_error(None);
                            desktop.set_connected(true);
                            desktop.push_channel(254, b"reconnecting target transport\n");
                            if renegotiate {
                                queue_serial(
                                    &mut serial_output,
                                    &hello().encode().expect("HELLO payload is bounded"),
                                );
                            }
                            next_resource_request = Instant::now();
                            next_scheduler_heartbeat = Instant::now();
                            next_hello_retry = Instant::now() + Duration::from_millis(250);
                        }
                        b'k' => {
                            queue_serial(
                                &mut serial_output,
                                &shell_restart_request(connection.mode()),
                            );
                            desktop.push_channel(254, b"restarting the shell\n");
                        }
                        b'B' => {
                            queue_serial(
                                &mut serial_output,
                                &system_reboot_request(connection.mode()),
                            );
                            desktop.push_channel(254, b"requesting warm SWTOS reboot\n");
                        }
                        b'e' => {
                            let channel = desktop.focused_channel();
                            if matches!(
                                desktop.focused_kind(),
                                PaneKind::Shell | PaneKind::Application
                            ) {
                                queue_serial(
                                    &mut serial_output,
                                    &multiplexed_input_frame(channel, &[0x1b]),
                                );
                                desktop.push_channel(channel, ESCAPE_ECHO);
                            }
                        }
                        _ => match desktop.command(byte) {
                            CommandOutcome::Detach => return Ok(()),
                            CommandOutcome::Save => {
                                if let Some(path) = options.session.as_deref()
                                    && let Err(error) = save_session(path, &desktop)
                                {
                                    desktop.set_error(Some(format!("session: {error}")));
                                }
                            }
                            CommandOutcome::Continue => {}
                        },
                    }
                    dirty = true;
                    continue;
                }
                if byte == options.prefix {
                    prefix_pending = true;
                    continue;
                }
                if byte == 0x03 {
                    return Ok(());
                }
                if desktop.help_enabled() && matches!(byte, b'q' | b'?' | 0x1b) {
                    desktop.command(byte);
                    dirty = true;
                    continue;
                }
                if desktop.copy_mode_enabled() {
                    handle_copy_input(&mut desktop, byte, &mut copy_escape_state);
                    dirty = true;
                    continue;
                }
                if desktop.focused_kind() == PaneKind::Debugger {
                    match byte {
                        b'\r' | b'\n' => {
                            desktop.push_channel(254, b"\n");
                            // "!<command>" is the shell, so process management
                            // lives in one place instead of being spelled
                            // differently in two. The reply appears in the
                            // shell's pane, which is where that shell's output
                            // has always gone.
                            if let Some(command) = debug_input.strip_prefix('!') {
                                let command = command.trim().to_string();
                                let note = if command.is_empty() {
                                    "usage: !<shell command>, e.g. !ps -l".to_string()
                                } else if is_shell_restart_request(&command) {
                                    // Not injected. The shell is endpoint 1,
                                    // and a request to kill it is most often
                                    // made because it has stopped reading what
                                    // it would be injected into.
                                    queue_serial(
                                        &mut serial_output,
                                        &shell_restart_request(connection.mode()),
                                    );
                                    "restarting the shell".to_string()
                                } else {
                                    injected = command.into_bytes();
                                    injected.push(b'\n');
                                    "sent to the shell; its reply is in the shell pane".to_string()
                                };
                                desktop.push_channel(254, format!("{note}\n").as_bytes());
                                debugger_prompt(&mut desktop);
                                debug_input.clear();
                                dirty = true;
                                continue;
                            }
                            let result = debugger.command(&debug_input, resources.snapshot());
                            debug_input.clear();
                            for line in result.lines {
                                desktop.push_channel(254, format!("{line}\n").as_bytes());
                            }
                            match result.request {
                                Some(request) => {
                                    queue_serial(&mut serial_output, &debug_request_frame(request));
                                    // The reply brings the prompt with it.
                                    debugger_prompt_due = None;
                                }
                                None => debugger_prompt(&mut desktop),
                            }
                        }
                        0x08 | 0x7f => {
                            // Erase on screen as well as in the buffer. The
                            // correction was always applied -- Enter ran the
                            // corrected line -- but the pane went on showing
                            // the mistake, so there was no way to see what
                            // would run.
                            if debug_input.pop().is_some() {
                                desktop.push_channel(254, &[0x08]);
                            }
                        }
                        0x20..=0x7e => {
                            debug_input.push(char::from(byte));
                            desktop.push_channel(254, &[byte]);
                        }
                        _ => {}
                    }
                    dirty = true;
                    continue;
                }
                if connection.mode() == Mode::Framed {
                    if desktop.focused_kind() == PaneKind::Shell {
                        match byte {
                            b'\r' | b'\n' => {
                                // "run <name>" gives the program its own
                                // terminal now; the old --tty=new spelling is
                                // still accepted and ignored by the target, so
                                // both name the pane here.
                                let line = shell_input.trim_end();
                                let line = line.strip_suffix(" --tty=new").unwrap_or(line);
                                if let Some(name) = line.strip_prefix("run ") {
                                    let name = name.trim();
                                    if !name.is_empty() {
                                        desktop.claim_application(name);
                                    }
                                }
                                shell_input.clear();
                            }
                            0x08 | 0x7f => {
                                shell_input.pop();
                            }
                            0x20..=0x7e => shell_input.push(char::from(byte)),
                            _ => {}
                        }
                    }
                    // SWTOS command lines are newline-terminated, while a raw
                    // host terminal normally reports Enter as carriage return.
                    // Numeric menu choices hid this mismatch because they are
                    // dispatched before the command-line parser runs.
                    let outgoing = if byte == b'\r' { b'\n' } else { byte };
                    let input_channels = desktop.input_channels();
                    if matches!(outgoing, b'\n' | 0x08 | 0x7f | 0x20..=0x7e) {
                        for &channel in &input_channels {
                            desktop.push_channel(channel, &[outgoing]);
                        }
                    } else if outgoing == 0x1b {
                        for &channel in &input_channels {
                            desktop.push_channel(channel, ESCAPE_ECHO);
                        }
                    }
                    for channel in input_channels {
                        queue_serial(
                            &mut serial_output,
                            &multiplexed_input_frame(channel, &[outgoing]),
                        );
                    }
                } else {
                    queue_serial(&mut serial_output, &[byte]);
                }
                // A typed character is echoed into its pane, and a pane that
                // has changed has to be drawn. This went unnoticed because
                // the monitor pane's figures changed every quarter second and
                // repainted the screen for everyone; typing looked immediate
                // only for as long as something else was moving.
                dirty = true;
            }
        }

        let size = terminal_size(tty.as_raw_fd());
        if size != last_size {
            last_size = size;
            dirty = true;
        }
        let now = Instant::now();
        if let Some(due) = debugger_prompt_due
            && now >= due
        {
            debugger_prompt(&mut desktop);
            debugger_prompt_due = None;
            dirty = true;
        }
        if now >= next_footer_repaint {
            dirty = true;
            next_footer_repaint = now + Duration::from_secs(1);
        }
        if connection.mode() == Mode::Framed && now >= next_resource_request {
            queue_serial(&mut serial_output, &resource_request_frame());
            next_resource_request = now + Duration::from_millis(250);
        }
        // Heartbeats must continue while HELLO is being negotiated.  In
        // particular, a detached frontend can leave a non-yielding task on
        // the CPU; SWTOS then needs clock IRQs to schedule the transport task
        // which consumes HELLO and emits HELLO_ACK.
        if now >= next_scheduler_heartbeat {
            let tick = (connected.elapsed().as_millis() as u32 / 10) & 0x00ff_ffff;
            queue_serial(&mut serial_output, &scheduler_heartbeat(tick));
            next_scheduler_heartbeat += Duration::from_millis(10);
            if next_scheduler_heartbeat < now {
                next_scheduler_heartbeat = now + Duration::from_millis(10);
            }
        }
        if connection.mode() == Mode::Plain && now >= next_hello_retry {
            queue_serial(
                &mut serial_output,
                &hello().encode().expect("HELLO payload is bounded"),
            );
            next_hello_retry = now + Duration::from_millis(250);
        }
        if connection.mode() == Mode::Framed && time_modes.any() && now >= next_time_frames {
            for mode in time_modes.active() {
                let tick = match mode {
                    TimeMode::Uptime => connected.elapsed().as_millis() as u32 / 10,
                    TimeMode::Clock => wall_centiseconds(),
                } & 0x00ff_ffff;
                queue_serial(&mut serial_output, &multiplexed_time_frame(mode, tick));
            }
            next_time_frames = now + Duration::from_secs(1);
        }
        if connection.mode() == Mode::Framed && !injected.is_empty() {
            let byte = injected.remove(0);
            queue_serial(&mut serial_output, &multiplexed_input_frame(0, &[byte]));
        }
        if connection.mode() == Mode::Framed && !debug_identity_sent {
            queue_serial(&mut serial_output, &debug_request_frame(identity_request()));
            debug_identity_sent = true;
        }
        if serial_output.len() >= MAX_WINDOWS_SERIAL_BACKLOG * 3 / 4 {
            desktop.set_error(Some(
                "serial output stalled; the detach key remains available".into(),
            ));
            dirty = true;
        }
        flush_serial(&mut serial, &mut serial_output)?;
        if dirty {
            repaint_desktop(&mut tty, &mut desktop)?;
        }
    }
}

fn run(options: &Options) -> io::Result<()> {
    if options.windows {
        return run_windows(options);
    }
    let mut serial = OpenOptions::new()
        .read(true)
        .write(true)
        .open(&options.device)?;
    let mut tty = OpenOptions::new().read(true).write(true).open("/dev/tty")?;
    let _serial_guard = TermiosGuard::serial(serial.as_raw_fd())?;
    let _tty_guard = TermiosGuard::terminal(tty.as_raw_fd())?;

    if options.verbose {
        eprintln!(
            "serial: {} at 921600 8N1 with RTS/CTS; delay={}; byte-delay={}; sync={}",
            options.device,
            options
                .delay
                .map(|value| format!("{}ms", value.as_millis()))
                .unwrap_or_else(|| "off".into()),
            options
                .byte_delay
                .map(|value| format!("{}us", value.as_micros()))
                .unwrap_or_else(|| "off".into()),
            options.sync
        );
    }

    let connected = Instant::now();
    let mut connection = ConnectionDecoder::default();
    if options.framed {
        let pending = resynchronize_heartbeat_parser(&mut serial)?;
        for item in connection.push(&pending) {
            if let StreamItem::Plain(bytes) = item {
                tty.write_all(&bytes)?;
            }
        }
        if !pending.is_empty() {
            tty.flush()?;
        }
        serial.write_all(&hello().encode().expect("HELLO payload is bounded"))?;
        serial.flush()?;
    }
    let mut time_mode = options.time_mode;
    let mut next_frame = connected;
    let mut menu_prompt = options.swtos && time_mode.is_none();
    let mut prompt_tail = Vec::<u8>::new();
    let mut input_line = Vec::<u8>::new();
    let mut discard_newline = false;
    let mut serial_buffer = [0_u8; 1024];
    let mut tty_buffer = [0_u8; 256];
    loop {
        let timeout = if time_mode.is_some() {
            next_frame
                .saturating_duration_since(Instant::now())
                .as_millis()
                .min(i32::MAX as u128) as i32
        } else {
            -1
        };
        let readable = match wait_readable([serial.as_raw_fd(), tty.as_raw_fd()], timeout) {
            Ok(readable) => readable,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        };

        if readable[0] {
            let count = serial.read(&mut serial_buffer)?;
            if count == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "serial device disconnected",
                ));
            }
            let mut terminal_bytes = Vec::new();
            if options.framed {
                for item in connection.push(&serial_buffer[..count]) {
                    match item {
                        StreamItem::Plain(bytes) => terminal_bytes.extend_from_slice(&bytes),
                        StreamItem::Frame(frame) if frame.kind == FrameType::TtyOutput => {
                            terminal_bytes.extend_from_slice(&frame.payload);
                        }
                        StreamItem::Frame(frame) if frame.kind == FrameType::ProtocolError => {
                            eprintln!(
                                "target protocol error: {}",
                                String::from_utf8_lossy(&frame.payload)
                            );
                        }
                        StreamItem::Frame(_) => {}
                        StreamItem::Error(error) => {
                            eprintln!("framed transport decode error: {error:?}")
                        }
                    }
                }
            } else {
                terminal_bytes.extend_from_slice(&serial_buffer[..count]);
            }
            tty.write_all(&terminal_bytes)?;
            tty.flush()?;
            if options.swtos {
                prompt_tail.extend_from_slice(&terminal_bytes);
                if prompt_tail
                    .windows(b"Choice: ".len())
                    .any(|part| part == b"Choice: ")
                {
                    menu_prompt = true;
                    time_mode = None;
                }
                let keep = b"Choice: ".len() - 1;
                if prompt_tail.len() > keep {
                    prompt_tail.drain(..prompt_tail.len() - keep);
                }
            }
        }

        if readable[1] {
            let count = tty.read(&mut tty_buffer)?;
            if count == 0 {
                return Ok(());
            }
            for &byte in &tty_buffer[..count] {
                if options.swtos && discard_newline && matches!(byte, b'\r' | b'\n') {
                    discard_newline = false;
                    continue;
                }
                match byte {
                    0x03 => return Ok(()),
                    0x12 => {
                        let Some(name) = prompt_for_file(&mut tty)? else {
                            return Ok(());
                        };
                        if name.is_empty() {
                            continue;
                        }
                        if let Err(error) = upload(Path::new(&name), &mut serial, &mut tty, options)
                        {
                            tty.write_all(format!("\r\nupload failed: {error}\r\n").as_bytes())?;
                            tty.flush()?;
                            if options.sync {
                                return Err(error);
                            }
                        }
                    }
                    _ => {
                        if options.swtos {
                            echo_swtos_key(&mut tty, byte)?;
                        }
                        if options.swtos && time_mode.is_some() && matches!(byte, 0x1b | 0x1d) {
                            if options.framed && connection.mode() == Mode::Framed {
                                serial.write_all(&multiplexed_input_frame(0, &[0x1b]))?;
                            } else {
                                serial.write_all(&[0x1b])?;
                            }
                            time_mode = None;
                            continue;
                        }
                        let outgoing = if options.swtos && byte == b'\r' {
                            b'\n'
                        } else {
                            byte
                        };
                        if options.framed && connection.mode() == Mode::Framed {
                            serial.write_all(&multiplexed_input_frame(0, &[outgoing]))?;
                        } else {
                            serial.write_all(&[outgoing])?;
                        }
                        serial.flush()?;
                        if options.swtos && menu_prompt {
                            if is_numeric_menu_choice(outgoing) && input_line.is_empty() {
                                time_mode = match outgoing {
                                    b'3' => Some(TimeMode::Uptime),
                                    b'4' => Some(TimeMode::Clock),
                                    _ => None,
                                };
                                if time_mode.is_some() {
                                    next_frame = Instant::now();
                                }
                                input_line.clear();
                                discard_newline = true;
                                menu_prompt = false;
                            } else if outgoing == b'\n' {
                                let command = String::from_utf8_lossy(&input_line)
                                    .trim()
                                    .to_ascii_lowercase();
                                time_mode = match command.as_str() {
                                    "run uptime" => Some(TimeMode::Uptime),
                                    "run clock" => Some(TimeMode::Clock),
                                    _ => None,
                                };
                                if time_mode.is_some() {
                                    next_frame = Instant::now();
                                }
                                input_line.clear();
                                menu_prompt = false;
                            } else {
                                input_line.push(outgoing);
                            }
                        }
                    }
                }
            }
        }

        let now = Instant::now();
        if let Some(mode) = time_mode
            && now >= next_frame
        {
            let tick = match mode {
                TimeMode::Uptime => connected.elapsed().as_millis() as u32 / 10,
                TimeMode::Clock => wall_centiseconds(),
            } & 0x00ff_ffff;
            if options.framed && connection.mode() == Mode::Framed {
                serial.write_all(&multiplexed_time_frame(mode, tick))?;
            } else {
                serial.write_all(&time_frame(mode, tick))?;
            }
            serial.flush()?;
            next_frame = now + Duration::from_secs(1);
        }
    }
}

fn main() -> ExitCode {
    let program = env::args().next().unwrap_or_else(|| "te-rs".into());
    let options = match parse_args(env::args()) {
        Ok(ParseResult::Help) => {
            print!("{}", help(&program));
            return ExitCode::SUCCESS;
        }
        Ok(ParseResult::Run(options)) => options,
        Err(error) => {
            eprintln!("error: {error}\n\n{}", help(&program));
            return ExitCode::from(2);
        }
    };

    match run(&options) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            // A hangup can surface on either side of the loop. The read path
            // already names it; a write reports the raw errno for the
            // pseudo-terminal or serial node, which says nothing about the
            // emulator or board having gone away. Report both.
            let vanished = matches!(
                error.kind(),
                io::ErrorKind::UnexpectedEof | io::ErrorKind::BrokenPipe
            ) || error.raw_os_error() == Some(libc::EIO);
            if vanished {
                eprintln!("{}: serial transport lost ({error})", options.device);
            } else {
                eprintln!("{}: {error}", options.device);
            }
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).into()).collect()
    }

    #[test]
    fn defaults_match_te() {
        let ParseResult::Run(options) = parse_args(args(&["te-rs"])).unwrap() else {
            panic!("expected runnable options");
        };
        assert_eq!(
            options,
            Options {
                device: DEFAULT_DEVICE.into(),
                delay: None,
                byte_delay: None,
                sync: false,
                verbose: false,
                swtos: false,
                framed: false,
                windows: false,
                prefix: 0x0f,
                debug_map: None,
                session: None,
                time_mode: None,
            }
        );
    }

    #[test]
    fn parses_all_options_and_device() {
        let ParseResult::Run(options) = parse_args(args(&[
            "te-rs",
            "--verbose",
            "--sync",
            "--delay",
            "7",
            "--byte-delay",
            "100",
            "/dev/ttyACM0",
        ]))
        .unwrap() else {
            panic!("expected runnable options");
        };
        assert_eq!(options.device, "/dev/ttyACM0");
        assert_eq!(options.delay, Some(Duration::from_millis(7)));
        assert_eq!(options.byte_delay, Some(Duration::from_micros(100)));
        assert!(options.sync);
        assert!(options.verbose);
        assert!(!options.swtos);
        assert!(!options.framed);
    }

    #[test]
    fn framed_mode_enables_swtos_negotiation() {
        let ParseResult::Run(options) = parse_args(args(&["te-rs", "--framed"])).unwrap() else {
            panic!("expected runnable options");
        };
        assert!(options.framed);
        assert!(options.swtos);
        assert_eq!(
            multiplexed_input_frame(2, b"x"),
            vec![0xa5, 0x5a, 1, 1, 2, 1, 0, b'x', 125]
        );
    }

    #[test]
    fn windows_mode_and_prefix_are_configurable() {
        let ParseResult::Run(options) = parse_args(args(&[
            "te-rs",
            "--windows",
            "--prefix",
            "^B",
            "--debug-map",
            "program.debug.json",
            "--session",
            "layout.json",
        ]))
        .unwrap() else {
            panic!("expected runnable options");
        };
        assert!(options.windows);
        assert!(options.framed);
        assert!(options.swtos);
        assert_eq!(options.prefix, 0x02);
        assert_eq!(options.debug_map, Some(PathBuf::from("program.debug.json")));
        assert_eq!(options.session, Some(PathBuf::from("layout.json")));
        assert_eq!(parse_prefix("x"), Ok(b'x'));
        assert!(parse_prefix("long").is_err());
    }

    #[test]
    fn copy_mode_consumes_arrow_sequences_for_local_scrolling() {
        let mut desktop = Desktop::default();
        desktop.command(b'y');
        let mut escape_state = 0;
        for byte in b"\x1b[A\x1b[C" {
            handle_copy_input(&mut desktop, *byte, &mut escape_state);
        }
        assert_eq!(escape_state, 0);
        assert!(desktop.copy_mode_enabled());
        handle_copy_input(&mut desktop, b'q', &mut escape_state);
        assert!(!desktop.copy_mode_enabled());
    }

    #[test]
    fn rejects_delay_outside_range() {
        assert!(parse_args(args(&["te-rs", "-d", "0"])).is_err());
        assert!(parse_args(args(&["te-rs", "-d", "11"])).is_err());
        assert!(parse_args(args(&["te-rs", "-b", "0"])).is_err());
        assert!(parse_args(args(&["te-rs", "-b", "10001"])).is_err());
    }

    #[test]
    fn recognizes_placeholder_monitor_errors_case_insensitively() {
        assert_eq!(
            monitor_error(b"Error: INVALID hex code\r\n"),
            Some("invalid")
        );
        assert_eq!(
            monitor_error(b"Load line is TOO LONG\r\n"),
            Some("too long")
        );
        assert_eq!(monitor_error(b"? Bad hex character:`\r\n"), Some("bad hex"));
    }

    #[test]
    fn permits_normal_monitor_output() {
        assert_eq!(monitor_error(b"L000000...\r\n"), None);
        assert_eq!(monitor_error(b"; comment\r\n"), None);
        assert_eq!(monitor_error(b"G000015\r\nJump...\r\n"), None);
    }

    #[test]
    fn recognizes_every_numeric_menu_choice() {
        for byte in b'1'..=b'5' {
            assert!(is_numeric_menu_choice(byte));
        }
        assert!(!is_numeric_menu_choice(b'0'));
        assert!(!is_numeric_menu_choice(b'6'));
    }

    #[test]
    fn the_prefix_is_never_a_line_ending() {
        // Ctrl-O, not Ctrl-J. LF is a line ending as well as a keystroke: it
        // arrives whenever text is pasted or input is scripted, and a prefix
        // that is also LF swallows the Enter at the end of every pasted line.
        // CR is Enter itself. Neither may be the prefix.
        // SAFETY: cfmakeraw accepts a termios structure, and this test only
        // inspects the input flags it clears.
        let attributes = unsafe { std::mem::zeroed() };
        let configured = terminal_attributes(attributes);
        assert_eq!(configured.c_iflag & libc::ICRNL, 0, "Enter would become LF");
        assert_eq!(configured.c_iflag & libc::INLCR, 0);
        assert_eq!(configured.c_iflag & libc::IGNCR, 0);
        // And the prefix is neither line ending, whatever it is set to.
        // And the default really is that key, not merely documented as it.
        let Ok(ParseResult::Run(options)) = parse_args(args(&["te-rs"])) else {
            panic!("bare invocation runs");
        };
        assert_ne!(options.prefix, b'\n', "a pasted line would arm the prefix");
        assert_ne!(options.prefix, b'\r');
        assert_eq!(options.prefix, 0x0f, "Ctrl-O");
    }

    #[test]
    fn terminal_output_translates_lf_to_crlf() {
        // SAFETY: cfmakeraw accepts a termios structure, and this test only
        // inspects the output flags set by terminal_attributes.
        let attributes = unsafe { std::mem::zeroed() };
        let configured = terminal_attributes(attributes);
        assert_ne!(configured.c_oflag & libc::OPOST, 0);
        assert_ne!(configured.c_oflag & libc::ONLCR, 0);
    }

    #[test]
    fn escapes_swtos_time_frames() {
        assert_eq!(
            time_frame(TimeMode::Uptime, 0x001dff),
            vec![0xff, 1, 0xff, 0, 0xff, 3, 0]
        );
        assert_eq!(time_frame(TimeMode::Clock, 1), vec![0xff, 2, 1, 0, 0]);
        assert_eq!(
            multiplexed_time_frame(TimeMode::Clock, 1),
            vec![0xa5, 0x5a, 1, 7, 0, 3, 0, 1, 0, 0, 12]
        );
    }

    #[test]
    fn the_restart_request_is_wrapped_once_the_link_is_framed() {
        // Raw on a plain link, because there is nothing in the way.
        assert_eq!(shell_restart_request(Mode::Plain), vec![0xff, 4]);

        // Wrapped once the adapter is reading frames, because it discards
        // anything that is not one -- and the two bytes still reach the
        // target's interrupt handler, which is the only reader that matters
        // when this is needed.
        let framed = shell_restart_request(Mode::Framed);
        assert_eq!(&framed[..2], &[0xa5, 0x5a]);
        assert_eq!(framed[3], PASSTHROUGH);
        assert_eq!(&framed[7..9], &SHELL_RESTART);
        let sum = framed[2..framed.len() - 1]
            .iter()
            .fold(0_u8, |sum, byte| sum.wrapping_add(*byte));
        assert_eq!(*framed.last().expect("a frame has a checksum"), sum);
    }

    #[test]
    fn the_warm_reboot_request_is_wrapped_once_the_link_is_framed() {
        assert_eq!(system_reboot_request(Mode::Plain), vec![0xff, 5]);
        let framed = system_reboot_request(Mode::Framed);
        assert_eq!(&framed[..2], &[0xa5, 0x5a]);
        assert_eq!(framed[3], PASSTHROUGH);
        assert_eq!(&framed[7..9], &SYSTEM_REBOOT);
    }

    #[test]
    fn scheduler_heartbeat_is_a_fixed_unescaped_five_byte_irq_frame() {
        assert_eq!(scheduler_heartbeat(0x1dff01), [0xff, 1, 1, 0xff, 0x1d]);
    }

    #[test]
    fn windows_serial_queue_is_ordered_and_bounded() {
        let mut output = VecDeque::new();
        assert!(queue_serial(&mut output, b"first"));
        assert!(queue_serial(&mut output, b"second"));
        assert_eq!(output.iter().copied().collect::<Vec<_>>(), b"firstsecond");

        output.resize(MAX_WINDOWS_SERIAL_BACKLOG, 0);
        assert!(!queue_serial(&mut output, b"overflow"));
        assert_eq!(output.len(), MAX_WINDOWS_SERIAL_BACKLOG);
    }
}
