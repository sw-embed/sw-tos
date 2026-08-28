use serde::{Deserialize, Serialize};
use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::fd::{AsRawFd, RawFd};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use te_rs::debug::{DebugConsole, DebugMap, identity_request};
use te_rs::protocol::{ConnectionDecoder, Frame, FrameType, Mode, StreamItem, hello};
use te_rs::resource::SnapshotAssembler;
use te_rs::ui::{CommandOutcome, Desktop, PaneKind};

const DEFAULT_DEVICE: &str = "/dev/ttyUSB0";
const SYNC_TIMEOUT: Duration = Duration::from_secs(2);
const MAX_MONITOR_RESPONSE: usize = 1024;

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
      --prefix <KEY>    Host-command prefix byte or ^X notation [default: ^A]
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
        prefix: 0x01,
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

fn scheduler_heartbeat(tick: u32) -> [u8; 5] {
    [0xff, 1, tick as u8, (tick >> 8) as u8, (tick >> 16) as u8]
}

fn resynchronize_heartbeat_parser(serial: &mut File) -> io::Result<()> {
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
            Ok(_) => continue,
            Err(error) => return Err(error),
        }
    }
    Ok(())
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

fn is_numeric_menu_choice(byte: u8) -> bool {
    matches!(byte, b'1'..=b'5')
}

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
    let mut resource_lines = resources.render(Instant::now());
    desktop.set_resources(&resource_lines);
    desktop.push_channel(254, b"SWTOS debugger: type help\n");
    if let Some(error) = debug_map_error {
        desktop.push_channel(254, format!("{error}\n").as_bytes());
    }
    let mut prefix_pending = false;
    let mut copy_escape_state = 0;
    let mut shell_input = String::new();
    let mut last_size = repaint_desktop(&mut tty, &mut desktop)?;
    let mut serial_buffer = [0_u8; 1024];
    let mut tty_buffer = [0_u8; 256];
    let mut next_resource_request = Instant::now();
    let mut next_scheduler_heartbeat = Instant::now();
    let mut next_hello_retry = Instant::now() + Duration::from_millis(250);
    let mut next_time_frames = Instant::now();
    let mut time_mode = None;

    resynchronize_heartbeat_parser(&mut serial)?;
    serial.write_all(&hello().encode().expect("HELLO payload is bounded"))?;
    serial.flush()?;

    loop {
        // A short timeout provides portable resize detection without installing
        // a process-global signal handler.
        let readable = match wait_readable([serial.as_raw_fd(), tty.as_raw_fd()], 10) {
            Ok(readable) => readable,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        };
        let mut dirty = false;

        if readable[0] {
            // A hangup makes the descriptor readable; the read then reports
            // the loss as zero bytes or as an error.
            let count = match serial.read(&mut serial_buffer) {
                Ok(count) => count,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => 0,
            };
            if count == 0 {
                desktop.set_connected(false);
                desktop.set_error(Some("transport lost".into()));
                repaint_desktop(&mut tty, &mut desktop)?;
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "serial transport lost",
                ));
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
                        desktop.push_channel(frame.channel, &frame.payload);
                    }
                    StreamItem::Frame(frame) if frame.kind == FrameType::ChannelOpen => {
                        let title = String::from_utf8_lossy(&frame.payload);
                        desktop.add_application(
                            frame.channel,
                            if title.is_empty() {
                                format!("TTY {}", frame.channel)
                            } else {
                                title.into_owned()
                            },
                        );
                    }
                    StreamItem::Frame(frame) if frame.kind == FrameType::ChannelClose => {
                        desktop.release_channel(frame.channel);
                    }
                    StreamItem::Frame(frame) if frame.kind == FrameType::ChannelTitle => {
                        desktop.set_channel_title(
                            frame.channel,
                            String::from_utf8_lossy(&frame.payload),
                        );
                    }
                    StreamItem::Frame(frame) if frame.kind == FrameType::ProtocolError => {
                        desktop
                            .set_error(Some(String::from_utf8_lossy(&frame.payload).into_owned()));
                    }
                    StreamItem::Frame(frame) if frame.kind == FrameType::ResourceSnapshot => {
                        if resources.push(&frame.payload, Instant::now()) {
                            time_mode = if resources.has_process_named("upti") {
                                Some(TimeMode::Uptime)
                            } else if resources.has_process_named("cloc") {
                                Some(TimeMode::Clock)
                            } else {
                                None
                            };
                            resource_lines = resources.render(Instant::now());
                            desktop.set_resources(&resource_lines);
                        }
                    }
                    StreamItem::Frame(frame) if frame.kind == FrameType::DebugResponse => {
                        for line in debugger.response(&frame.payload) {
                            desktop.push_channel(254, format!("{line}\n").as_bytes());
                        }
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
                            if let Some(path) = options.session.as_deref() {
                                if let Err(error) = load_session(path, &mut desktop) {
                                    desktop.set_error(Some(format!("session: {error}")));
                                }
                            }
                        }
                        b'r' => {
                            let renegotiate = connection.mode() == Mode::Plain;
                            if renegotiate {
                                connection.resynchronize();
                                resynchronize_heartbeat_parser(&mut serial)?;
                            }
                            resources = SnapshotAssembler::default();
                            debug_identity_sent = false;
                            transport_decode_error = false;
                            resource_lines = resources.render(Instant::now());
                            desktop.set_resources(&resource_lines);
                            desktop.set_error(None);
                            desktop.set_connected(true);
                            desktop.push_channel(254, b"reconnecting target transport\n");
                            if renegotiate {
                                serial.write_all(
                                    &hello().encode().expect("HELLO payload is bounded"),
                                )?;
                                serial.flush()?;
                            }
                            next_resource_request = Instant::now();
                            next_scheduler_heartbeat = Instant::now();
                            next_hello_retry = Instant::now() + Duration::from_millis(250);
                        }
                        b'e' => {
                            let channel = desktop.focused_channel();
                            if matches!(
                                desktop.focused_kind(),
                                PaneKind::Shell | PaneKind::Application
                            ) {
                                serial.write_all(&multiplexed_input_frame(channel, &[0x1b]))?;
                                serial.flush()?;
                            }
                        }
                        _ => match desktop.command(byte) {
                            CommandOutcome::Detach => return Ok(()),
                            CommandOutcome::Save => {
                                if let Some(path) = options.session.as_deref() {
                                    if let Err(error) = save_session(path, &desktop) {
                                        desktop.set_error(Some(format!("session: {error}")));
                                    }
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
                            let result = debugger.command(&debug_input);
                            debug_input.clear();
                            for line in result.lines {
                                desktop.push_channel(254, format!("{line}\n").as_bytes());
                            }
                            if let Some(request) = result.request {
                                serial.write_all(&debug_request_frame(request))?;
                                serial.flush()?;
                            }
                        }
                        0x08 | 0x7f => {
                            debug_input.pop();
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
                                let command = shell_input.strip_suffix(" --tty=new");
                                if let Some(command) = command {
                                    desktop.claim_application(
                                        command.strip_prefix("run ").unwrap_or(command),
                                    );
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
                    }
                    for channel in input_channels {
                        serial.write_all(&multiplexed_input_frame(channel, &[outgoing]))?;
                    }
                } else {
                    serial.write_all(&[byte])?;
                }
                serial.flush()?;
            }
        }

        let size = terminal_size(tty.as_raw_fd());
        if size != last_size {
            last_size = size;
            dirty = true;
        }
        let now = Instant::now();
        let latest_resource_lines = resources.render(now);
        if latest_resource_lines != resource_lines {
            resource_lines = latest_resource_lines;
            desktop.set_resources(&resource_lines);
            dirty = true;
        }
        if connection.mode() == Mode::Framed && now >= next_resource_request {
            serial.write_all(&resource_request_frame())?;
            serial.flush()?;
            next_resource_request = now + Duration::from_millis(250);
        }
        // Heartbeats must continue while HELLO is being negotiated.  In
        // particular, a detached frontend can leave a non-yielding task on
        // the CPU; SWTOS then needs clock IRQs to schedule the transport task
        // which consumes HELLO and emits HELLO_ACK.
        if now >= next_scheduler_heartbeat {
            let tick = (connected.elapsed().as_millis() as u32 / 10) & 0x00ff_ffff;
            serial.write_all(&scheduler_heartbeat(tick))?;
            serial.flush()?;
            next_scheduler_heartbeat += Duration::from_millis(10);
            if next_scheduler_heartbeat < now {
                next_scheduler_heartbeat = now + Duration::from_millis(10);
            }
        }
        if connection.mode() == Mode::Plain && now >= next_hello_retry {
            serial.write_all(&hello().encode().expect("HELLO payload is bounded"))?;
            serial.flush()?;
            next_hello_retry = now + Duration::from_millis(250);
        }
        if connection.mode() == Mode::Framed && time_mode.is_some() && now >= next_time_frames {
            let mode = time_mode.expect("checked active time mode");
            let tick = match mode {
                TimeMode::Uptime => connected.elapsed().as_millis() as u32 / 10,
                TimeMode::Clock => wall_centiseconds(),
            } & 0x00ff_ffff;
            serial.write_all(&multiplexed_time_frame(mode, tick))?;
            serial.flush()?;
            next_time_frames = now + Duration::from_secs(1);
        }
        if connection.mode() == Mode::Framed && !debug_identity_sent {
            serial.write_all(&debug_request_frame(identity_request()))?;
            serial.flush()?;
            debug_identity_sent = true;
        }
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
        resynchronize_heartbeat_parser(&mut serial)?;
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
        if let Some(mode) = time_mode {
            if now >= next_frame {
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
            eprintln!("{}: {error}", options.device);
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
                prefix: 0x01,
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
    fn scheduler_heartbeat_is_a_fixed_unescaped_five_byte_irq_frame() {
        assert_eq!(scheduler_heartbeat(0x1dff01), [0xff, 1, 1, 0xff, 0x1d]);
    }
}
