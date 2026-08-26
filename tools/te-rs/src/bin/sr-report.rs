use std::env;
use std::io::{BufReader, Read};
use std::path::Path;
use std::process::{Command, Stdio};

const BAUD: f64 = 921_600.0;

#[derive(Clone, Copy, PartialEq)]
enum Mode {
    Text,
    RxHex,
    TxHex,
    Info,
}

fn usage(program: &str) -> String {
    format!(
        "Usage: {program} SESSION.sr [text|rx-hex|tx-hex|info]\n\n\
         text    board TX (D3) as timestamped text lines (default)\n\
         rx-hex  host TX / board RX (D2) as timestamped bytes\n\
         tx-hex  board TX / host RX (D3) as timestamped bytes\n\
         info    capture metadata and established wiring only"
    )
}

fn unzip_member(session: &Path, member: &str) -> Result<Vec<u8>, String> {
    let output = Command::new("unzip")
        .args(["-p"])
        .arg(session)
        .arg(member)
        .output()
        .map_err(|error| format!("could not run unzip: {error}"))?;
    if !output.status.success() {
        return Err(format!(
            "unzip could not read {member} from {}",
            session.display()
        ));
    }
    Ok(output.stdout)
}

fn samplerate(metadata: &str) -> Result<u64, String> {
    let value = metadata
        .lines()
        .find_map(|line| line.strip_prefix("samplerate="))
        .ok_or("session metadata has no samplerate")?;
    let mut fields = value.split_whitespace();
    let number: f64 = fields
        .next()
        .ok_or("empty samplerate")?
        .parse()
        .map_err(|_| format!("invalid samplerate: {value}"))?;
    let scale = match fields.next().unwrap_or("Hz") {
        "Hz" => 1.0,
        "kHz" => 1_000.0,
        "MHz" => 1_000_000.0,
        unit => return Err(format!("unsupported samplerate unit: {unit}")),
    };
    Ok((number * scale) as u64)
}

struct UartDecoder {
    channel: u8,
    samples_per_bit: f64,
    previous: bool,
    next_sample: f64,
    bit: u8,
    byte: u8,
    start: u64,
    receiving: bool,
}

impl UartDecoder {
    fn new(channel: u8, rate: u64) -> Self {
        Self {
            channel,
            samples_per_bit: rate as f64 / BAUD,
            previous: true,
            next_sample: 0.0,
            bit: 0,
            byte: 0,
            start: 0,
            receiving: false,
        }
    }

    fn sample(&mut self, index: u64, packed: u8) -> Option<(u64, u8)> {
        let level = packed & (1 << self.channel) != 0;
        if !self.receiving && self.previous && !level {
            self.receiving = true;
            self.start = index;
            self.bit = 0;
            self.byte = 0;
            self.next_sample = index as f64 + 1.5 * self.samples_per_bit;
        } else if self.receiving && index as f64 >= self.next_sample {
            if self.bit < 8 {
                if level {
                    self.byte |= 1 << self.bit;
                }
                self.bit += 1;
                self.next_sample += self.samples_per_bit;
            } else {
                self.receiving = false;
                self.previous = level;
                return level.then_some((self.start, self.byte));
            }
        }
        self.previous = level;
        None
    }
}

fn run() -> Result<(), String> {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 || args.len() > 3 || args[1] == "--help" || args[1] == "-h" {
        return if args
            .get(1)
            .is_some_and(|arg| arg == "--help" || arg == "-h")
        {
            println!("{}", usage(&args[0]));
            Ok(())
        } else {
            Err(usage(&args[0]))
        };
    }
    let session = Path::new(&args[1]);
    if !session.is_file() {
        return Err(format!("cannot read sigrok session: {}", session.display()));
    }
    let mode = match args.get(2).map(String::as_str).unwrap_or("text") {
        "text" => Mode::Text,
        "rx-hex" => Mode::RxHex,
        "tx-hex" => Mode::TxHex,
        "info" => Mode::Info,
        value => return Err(format!("unknown mode: {value}\n{}", usage(&args[0]))),
    };
    let metadata = String::from_utf8(unzip_member(session, "metadata")?)
        .map_err(|_| "session metadata is not UTF-8")?;
    let rate = samplerate(&metadata)?;
    println!("Session: {}", session.display());
    println!("{metadata}");
    println!("Wiring: D0=board RTS, D1=host RTS, D2=host TX, D3=board TX");
    if mode == Mode::Info {
        return Ok(());
    }

    let channel = if mode == Mode::RxHex { 2 } else { 3 };
    let mut child = Command::new("unzip")
        .args(["-p"])
        .arg(session)
        .arg("logic-1-*")
        .stdout(Stdio::piped())
        .spawn()
        .map_err(|error| format!("could not run unzip: {error}"))?;
    let stdout = child.stdout.take().ok_or("could not read unzip output")?;
    let mut reader = BufReader::new(stdout);
    let mut decoder = UartDecoder::new(channel, rate);
    let mut buffer = [0_u8; 64 * 1024];
    let mut index = 0_u64;
    let mut line = Vec::new();
    let mut line_start = 0_u64;
    println!();
    println!(
        "Decoded {} at 921600 8-N-1:",
        if channel == 3 {
            "D3 board TX"
        } else {
            "D2 host TX"
        }
    );
    loop {
        let count = reader
            .read(&mut buffer)
            .map_err(|error| error.to_string())?;
        if count == 0 {
            break;
        }
        for packed in &buffer[..count] {
            if let Some((start, byte)) = decoder.sample(index, *packed) {
                if mode == Mode::Text {
                    if line.is_empty() {
                        line_start = start;
                    }
                    match byte {
                        b'\n' => {
                            println!(
                                "[{:.6} s] {}",
                                line_start as f64 / rate as f64,
                                String::from_utf8_lossy(&line)
                            );
                            line.clear();
                        }
                        b'\r' => {}
                        0x20..=0x7e => line.push(byte),
                        _ => line.extend_from_slice(format!("<{byte:02X}>").as_bytes()),
                    }
                } else {
                    println!("[{:.6} s] {byte:02X}", start as f64 / rate as f64);
                }
            }
            index += 1;
        }
    }
    if !line.is_empty() {
        println!(
            "[{:.6} s] {}",
            line_start as f64 / rate as f64,
            String::from_utf8_lossy(&line)
        );
    }
    let status = child.wait().map_err(|error| error.to_string())?;
    if !status.success() {
        return Err("unzip failed while streaming logic samples".into());
    }
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("error: {error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::UartDecoder;

    #[test]
    fn decodes_uart_byte() {
        let rate = 9_216_000;
        let mut samples = vec![1_u8; 20];
        let byte = b'A';
        samples.extend(std::iter::repeat_n(0, 10));
        for bit in 0..8 {
            samples.extend(std::iter::repeat_n((byte >> bit) & 1, 10));
        }
        samples.extend(std::iter::repeat_n(1, 20));
        let mut decoder = UartDecoder::new(0, rate);
        let decoded: Vec<_> = samples
            .into_iter()
            .enumerate()
            .filter_map(|(index, value)| decoder.sample(index as u64, value))
            .collect();
        assert_eq!(decoded.len(), 1);
        assert_eq!(decoded[0].1, byte);
    }
}
