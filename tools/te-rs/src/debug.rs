//! Build-matched symbolic inspection for COR24 debug artifacts.

use crate::resource::ResourceSnapshot;
use serde::Deserialize;
use std::fs;
use std::path::Path;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct Symbol {
    pub name: String,
    pub address: u32,
    pub module: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct Function {
    pub name: String,
    pub address: u32,
    pub end: u32,
    pub module: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct Instruction {
    pub address: u32,
    pub size: u32,
    pub bytes: String,
    pub text: String,
    pub source: String,
    pub line: u32,
}

#[derive(Clone, Debug, Deserialize)]
pub struct DebugMap {
    pub format: String,
    pub build_id: String,
    pub build_id_size: u32,
    pub image_sha256: String,
    pub image_size: u32,
    pub symbols: Vec<Symbol>,
    pub functions: Vec<Function>,
    pub instructions: Vec<Instruction>,
}

impl DebugMap {
    pub fn load(path: &Path) -> Result<Self, String> {
        let contents = fs::read_to_string(path)
            .map_err(|error| format!("cannot read {}: {error}", path.display()))?;
        let map: Self = serde_json::from_str(&contents)
            .map_err(|error| format!("invalid {}: {error}", path.display()))?;
        if map.format != "swtos-debug-v1" {
            return Err(format!("unsupported debug format '{}'", map.format));
        }
        map.build_id_value()?;
        Ok(map)
    }

    pub fn build_id_value(&self) -> Result<u32, String> {
        let value = self
            .build_id
            .strip_prefix("crc24:")
            .ok_or_else(|| format!("invalid build ID '{}'", self.build_id))?;
        let number = u32::from_str_radix(value, 16)
            .map_err(|_| format!("invalid build ID '{}'", self.build_id))?;
        if number <= 0xff_ffff {
            Ok(number)
        } else {
            Err(format!("invalid build ID '{}'", self.build_id))
        }
    }

    pub fn require_match(&self, target: u32) -> Result<(), String> {
        let expected = self.build_id_value()?;
        if expected == target {
            Ok(())
        } else {
            Err(format!(
                "symbol map mismatch: target crc24:{target:06x}, map {}",
                self.build_id
            ))
        }
    }

    pub fn symbol(&self, name: &str) -> Option<&Symbol> {
        self.symbols.iter().find(|symbol| symbol.name == name)
    }

    /// The instruction containing `address`, if the map describes one.
    ///
    /// The search runs backwards to the nearest instruction at or below the
    /// address, then confirms the address actually falls inside it. Without
    /// that bound every address above the image resolved to the last mapped
    /// instruction, so `list` answered a confident, wrong source location for
    /// any address outside the linked program -- and those are common, because
    /// `regs` reports program counters in runtime-loaded arena memory that the
    /// map never covers.
    pub fn source_at(&self, address: u32) -> Option<&Instruction> {
        self.instructions
            .iter()
            .rev()
            .find(|instruction| instruction.address <= address)
            .filter(|instruction| address < instruction.address + instruction.size)
    }

    /// Lowest and highest addresses the map describes, for diagnostics.
    pub fn mapped_extent(&self) -> Option<(u32, u32)> {
        let first = self.instructions.first()?;
        let last = self.instructions.last()?;
        Some((first.address, last.address + last.size - 1))
    }

    pub fn disassemble(&self, address: u32, count: usize) -> Vec<&Instruction> {
        self.instructions
            .iter()
            .filter(|instruction| instruction.address >= address)
            .take(count)
            .collect()
    }

    pub fn source_location(&self, value: &str) -> Option<u32> {
        let (source, line) = value.rsplit_once(':')?;
        let line = line.parse::<u32>().ok()?;
        self.instructions
            .iter()
            .find(|item| item.line == line && item.source.ends_with(source))
            .map(|item| item.address)
    }

    fn function_at(&self, address: u32) -> Option<&Function> {
        self.functions
            .iter()
            .find(|function| function.address <= address && address < function.end)
    }
}

pub fn identity_request() -> Vec<u8> {
    vec![1]
}

pub fn registers_request(endpoint: u8) -> Vec<u8> {
    vec![2, endpoint]
}

pub fn memory_request(address: u32, length: u8) -> Result<Vec<u8>, String> {
    if length == 0 || length > 12 || address > 0xff_ffff {
        return Err("memory request requires a 24-bit address and 1..12 bytes".into());
    }
    Ok(vec![
        3,
        address as u8,
        (address >> 8) as u8,
        (address >> 16) as u8,
        length,
    ])
}


/// COR24-TB physical address space. Hardware facts, fixed by the board.
const HARDWARE: &[(&str, &str)] = &[
    ("000000-0FFFFF", "1 MB SRAM (ISSI IS61WV10248EDBLL)"),
    ("100000-FDFFFF", "unmapped; addressable, reads zero"),
    ("FEE000-FEFFFF", "EBR window, 8 KB addressable"),
    ("FEE000-FEEBFF", "EBR populated, 3 KB on the MachXO"),
    ("FF0000-FFFFFF", "I/O space: LEDs, UART, SPI, I2C"),
];

/// How SWTOS intends to use those ranges. Mirrors the memory map in
/// docs/plan.md section 5 and the kernel constants in
/// hal/cor24/catalog-spawn.s; the frontend cannot read either at runtime, so
/// a kernel layout change must be reflected here.
const PLANNED: &[(&str, &str)] = &[
    ("000000-......", "kernel text, resident programs, catalog, data"),
    ("......-0EFFFF", "heap: loaded image text, shadow, private state"),
    ("0F0000-0FFFFF", "process stacks, 64 KB, allocated downward"),
    ("FEEC00", "kernel stack top; grows down"),
    ("FEEB01-FEEBFF", "kernel and boot stack reserve, 255 B"),
];

/// Configured process-stack region, from hal/cor24/catalog-spawn.s. Loaded
/// image text and private state come from the heap below it, which the target
/// does not yet report.
const ARENA_TOP: u32 = 0x0010_0000;
const ARENA_CAPACITY: u32 = 0x0001_0000;
const SRAM_END: u32 = 0x000F_FFFF;

pub struct DebugConsole {
    pub map: Option<DebugMap>,
    target_build_id: Option<u32>,
}

pub struct CommandResult {
    pub lines: Vec<String>,
    pub request: Option<Vec<u8>>,
}

impl DebugConsole {
    pub fn new(map: Option<DebugMap>) -> Self {
        Self {
            map,
            target_build_id: None,
        }
    }

    pub fn response(&mut self, payload: &[u8]) -> Vec<String> {
        match payload {
            [1, low, middle, high] => {
                let target = u32::from(*low) | (u32::from(*middle) << 8) | (u32::from(*high) << 16);
                self.target_build_id = Some(target);
                match &self.map {
                    Some(map) => match map.require_match(target) {
                        Ok(()) => vec![format!("build matched {}", map.build_id)],
                        Err(error) => vec![error],
                    },
                    None => vec![format!("target build crc24:{target:06x}; no map loaded")],
                }
            }
            [2, endpoint, part, values @ ..] if values.len() % 3 == 0 => {
                let names: &[&str] = if *part == 0 {
                    &["r0", "r1", "r2", "sp"]
                } else {
                    &["pc", "status"]
                };
                let rendered = values
                    .chunks_exact(3)
                    .zip(names)
                    .map(|(bytes, name)| format!("{name}={:06x}", u24(bytes)))
                    .collect::<Vec<_>>()
                    .join(" ");
                vec![format!("ep={endpoint} {rendered}")]
            }
            [3, a0, a1, a2, data @ ..] => {
                let address = u24(&[*a0, *a1, *a2]);
                vec![format!(
                    "{address:06x}: {}",
                    data.iter()
                        .map(|byte| format!("{byte:02x}"))
                        .collect::<Vec<_>>()
                        .join(" ")
                )]
            }
            [4, reason, a0, a1, a2] => {
                let pc = u24(&[*a0, *a1, *a2]);
                let reason = match reason {
                    1 => "breakpoint",
                    2 => "paused",
                    3 => "running",
                    4 => "halted",
                    5 => "invalid instruction",
                    6 => "stack overflow",
                    7 => "stack underflow",
                    _ => "unknown",
                };
                vec![format!("{reason} at {pc:06x}")]
            }
            [8, count, addresses @ ..] if addresses.len() == usize::from(*count) * 3 => {
                if *count == 0 {
                    vec!["breakpoints: none".into()]
                } else {
                    addresses
                        .chunks_exact(3)
                        .enumerate()
                        .map(|(index, bytes)| {
                            let address = u24(bytes);
                            let name = self
                                .map
                                .as_ref()
                                .and_then(|map| map.function_at(address))
                                .map(|function| format!(" {}", function.name))
                                .unwrap_or_default();
                            format!("{}: {address:06x}{name}", index + 1)
                        })
                        .collect()
                }
            }
            [11, pc, p1, p2, fp, f1, f2, sp, s1, s2, words @ ..] if words.len() % 3 == 0 => {
                let pc = u24(&[*pc, *p1, *p2]);
                let fp = u24(&[*fp, *f1, *f2]);
                let sp = u24(&[*sp, *s1, *s2]);
                let mut lines = vec![format!(
                    "#0 {} pc={pc:06x} fp={fp:06x} sp={sp:06x}",
                    self.frame_name(pc)
                )];
                for address in words.chunks_exact(3).map(u24).filter(|value| *value != 0) {
                    if let Some(map) = &self.map
                        && let Some(function) = map.function_at(address)
                        && !lines
                            .iter()
                            .any(|line| line.contains(&format!("pc={address:06x}")))
                        {
                            lines.push(format!(
                                "#{} {} pc={address:06x}",
                                lines.len(),
                                function.name
                            ));
                        }
                }
                if lines.len() == 1 {
                    lines.push("best-effort stack scan found no caller".into());
                }
                lines
            }
            [12] => vec!["detached from emulator".into()],
            [13, endpoint, status] => vec![if *status == 0 {
                format!("kill requested for endpoint {endpoint}")
            } else {
                format!("cannot kill endpoint {endpoint}: status {status}")
            }],
            _ => vec!["invalid debug response".into()],
        }
    }

    pub fn command(&self, line: &str, resources: Option<&ResourceSnapshot>) -> CommandResult {
        let words: Vec<&str> = line.split_whitespace().collect();
        let result = match words.as_slice() {
            ["map"] => self.map_command(resources, "all"),
            ["map", view] => self.map_command(resources, view),
            ["sym", name] => self.symbol_command(name),
            ["list", location] => self.list_command(location),
            ["dis", location] => self.disassemble_command(location, 8),
            ["dis", location, count] => count
                .parse::<usize>()
                .map_err(|_| "count must be decimal".to_string())
                .and_then(|count| self.disassemble_command(location, count)),
            ["regs"] => Ok(CommandResult {
                lines: vec!["requesting registers for endpoint 1".into()],
                request: Some(registers_request(1)),
            }),
            ["regs", endpoint] => endpoint
                .parse::<u8>()
                .map(|endpoint| CommandResult {
                    lines: vec![format!("requesting registers for endpoint {endpoint}")],
                    request: Some(registers_request(endpoint)),
                })
                .map_err(|_| "endpoint must be decimal".to_string()),
            ["x", address] => self.memory_command(address, 12),
            ["x", address, length] => length
                .parse::<u8>()
                .map_err(|_| "length must be decimal".to_string())
                .and_then(|length| self.memory_command(address, length)),
            ["pause"] => Ok(request("pausing emulator", vec![4])),
            ["continue"] | ["c"] => Ok(request("continuing emulator", vec![5])),
            ["break", location] | ["b", location] => self.breakpoint_command(location, 6),
            ["bl"] => Ok(request("requesting breakpoints", vec![8])),
            ["delete", location] => self.breakpoint_command(location, 7),
            ["step"] | ["s"] => Ok(request("stepping one instruction", vec![9])),
            ["next"] | ["n"] => Ok(request("stepping over call", vec![10])),
            ["bt"] => Ok(request("requesting ABI backtrace", vec![11])),
            ["kill", endpoint] => endpoint
                .parse::<u8>()
                .map(|endpoint| {
                    request(&format!("killing endpoint {endpoint}"), vec![13, endpoint])
                })
                .map_err(|_| "endpoint must be decimal".to_string()),
            ["detach"] => Ok(request("detaching from emulator", vec![12])),
            ["help"] | [] => Ok(text(
                "map [hw|plan|live] | sym NAME | list LOC | dis LOC [N] | regs [EP] | x ADDR [N] | kill EP | pause | continue | break LOC | bl | delete LOC | step | next | bt | detach",
            )),
            _ => Err("unknown debugger command; use help".into()),
        };
        result.unwrap_or_else(|error| text(&error))
    }


    /// Three views of memory: what the board has, how SWTOS means to use it,
    /// and what is actually there now.
    fn map_command(
        &self,
        resources: Option<&ResourceSnapshot>,
        view: &str,
    ) -> Result<CommandResult, String> {
        let (hardware, planned, live) = match view {
            "all" => (true, true, true),
            "hw" => (true, false, false),
            "plan" => (false, true, false),
            "live" => (false, false, true),
            other => return Err(format!("unknown map view '{other}'; use hw, plan, or live")),
        };
        let mut lines = Vec::new();
        if hardware {
            lines.push("hardware".into());
            for (range, use_) in HARDWARE {
                lines.push(format!("  {range:<13} {use_}"));
            }
        }
        if planned {
            lines.push("planned".into());
            for (range, use_) in PLANNED {
                lines.push(format!("  {range:<13} {use_}"));
            }
        }
        if live {
            lines.push("actual".into());
            match self.map.as_ref().and_then(|map| map.mapped_extent()) {
                Some((low, high)) => {
                    let size = high - low + 1;
                    lines.push(format!("  {low:06x}-{high:06x} image, {size} B linked"));
                    let heap_end = ARENA_TOP - ARENA_CAPACITY - 1;
                    let capacity = heap_end - high;
                    let used = resources.map_or(0, |snapshot| snapshot.memory.heap_current);
                    lines.push(format!(
                        "  {:06x}-{heap_end:06x} heap {used}/{capacity} B, free {} B",
                        high + 1,
                        capacity.saturating_sub(used)
                    ));
                }
                None => lines.push("  image extent unknown; no matching debug map".into()),
            }
            match resources {
                Some(snapshot) => {
                    let used = snapshot.memory.current;
                    let free = ARENA_CAPACITY.saturating_sub(used);
                    lines.push(format!(
                        "  {:06x}-{SRAM_END:06x} stacks {used}/{ARENA_CAPACITY} B, free {free} B",
                        ARENA_TOP - ARENA_CAPACITY
                    ));
                    if used > ARENA_CAPACITY {
                        lines.push(
                            "  arena use exceeds the configured capacity; constants stale".into(),
                        );
                    }
                    lines.push(format!(
                        "  stack peak {} B, kernel stack peak {} B, failures {}",
                        snapshot.memory.peak,
                        snapshot.memory.kernel_stack_peak,
                        snapshot.memory.allocation_failures
                    ));
                    lines.push(format!(
                        "  slots {}/{} used",
                        snapshot.memory.used_slots, snapshot.memory.total_slots
                    ));
                    for process in snapshot.processes.values() {
                        lines.push(format!(
                            "  ep={} {:<8} stack {}w state {}w",
                            process.endpoint,
                            process.name,
                            process.stack_words,
                            process.state_words
                        ));
                    }
                }
                None => lines.push("  no resource snapshot yet".into()),
            }
        }
        Ok(CommandResult {
            lines,
            request: None,
        })
    }

    fn matched_map(&self) -> Result<&DebugMap, String> {
        let map = self.map.as_ref().ok_or("no debug map loaded")?;
        let target = self
            .target_build_id
            .ok_or("target build identity not received")?;
        map.require_match(target)?;
        Ok(map)
    }

    fn symbol_command(&self, name: &str) -> Result<CommandResult, String> {
        let symbol = self
            .matched_map()?
            .symbol(name)
            .ok_or_else(|| format!("unknown symbol '{name}'"))?;
        Ok(text(&format!(
            "{} = {:06x} ({})",
            symbol.name, symbol.address, symbol.module
        )))
    }

    fn address(&self, value: &str) -> Result<u32, String> {
        if let Ok(address) = parse_address(value) {
            return Ok(address);
        }
        if let Some(symbol) = self.matched_map()?.symbol(value) {
            return Ok(symbol.address);
        }
        if let Some(address) = self.matched_map()?.source_location(value) {
            return Ok(address);
        }
        parse_address(value)
    }

    fn frame_name(&self, address: u32) -> String {
        self.map
            .as_ref()
            .and_then(|map| map.function_at(address))
            .map(|function| function.name.clone())
            .unwrap_or_else(|| "??".into())
    }

    fn breakpoint_command(&self, value: &str, opcode: u8) -> Result<CommandResult, String> {
        let address = self.address(value)?;
        let mut payload = vec![opcode];
        payload.extend([address as u8, (address >> 8) as u8, (address >> 16) as u8]);
        Ok(request(
            if opcode == 6 {
                "setting breakpoint"
            } else {
                "deleting breakpoint"
            },
            payload,
        ))
    }

    fn list_command(&self, value: &str) -> Result<CommandResult, String> {
        let address = self.address(value)?;
        let map = self.matched_map()?;
        let instruction = map.source_at(address).ok_or_else(|| match map.mapped_extent() {
            Some((low, high)) => {
                format!("no source for {address:06x}; image maps {low:06x}-{high:06x}")
            }
            None => format!("no source for {address:06x}"),
        })?;
        Ok(text(&format!(
            "{:06x} {}:{} {}",
            instruction.address, instruction.source, instruction.line, instruction.text
        )))
    }

    fn disassemble_command(&self, value: &str, count: usize) -> Result<CommandResult, String> {
        let address = self.address(value)?;
        let lines: Vec<String> = self
            .matched_map()?
            .disassemble(address, count.min(32))
            .into_iter()
            .map(|item| format!("{:06x} {:<8} {}", item.address, item.bytes, item.text))
            .collect();
        if lines.is_empty() {
            // An address outside the image disassembles to nothing. Saying so
            // matters because the addresses an operator pastes in come from
            // `regs`, which reports a stale program counter for an endpoint
            // that has exited, and silence reads as a broken command.
            return Err(match self.matched_map()?.mapped_extent() {
                Some((low, high)) => {
                    format!("no instructions at {address:06x}; image maps {low:06x}-{high:06x}")
                }
                None => format!("no instructions at {address:06x}"),
            });
        }
        Ok(CommandResult {
            lines,
            request: None,
        })
    }

    fn memory_command(&self, value: &str, length: u8) -> Result<CommandResult, String> {
        let address = parse_address(value)?;
        Ok(CommandResult {
            lines: vec![format!("requesting {length} bytes at {address:06x}")],
            request: Some(memory_request(address, length)?),
        })
    }
}

fn text(value: &str) -> CommandResult {
    CommandResult {
        lines: vec![value.into()],
        request: None,
    }
}

fn request(message: &str, payload: Vec<u8>) -> CommandResult {
    CommandResult {
        lines: vec![message.into()],
        request: Some(payload),
    }
}

fn parse_address(value: &str) -> Result<u32, String> {
    let digits = value.strip_prefix("0x").unwrap_or(value);
    u32::from_str_radix(digits, 16)
        .ok()
        .filter(|address| *address <= 0xff_ffff)
        .ok_or_else(|| format!("invalid 24-bit address '{value}'"))
}

fn u24(bytes: &[u8]) -> u32 {
    u32::from(bytes[0]) | (u32::from(bytes[1]) << 8) | (u32::from(bytes[2]) << 16)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn listing_outside_the_image_reports_the_gap_instead_of_the_nearest_line() {
        let mut console = DebugConsole::new(Some(map()));
        console.response(&[1, 0x56, 0x34, 0x12]);
        // 0x13 is one past the final mapped instruction, and fee7db is the
        // kind of arena program counter `regs` reports for a loaded image.
        for outside in ["13", "fee7db"] {
            let result = console.command(&format!("list {outside}"), None);
            assert!(
                result.lines.iter().any(|line| line.contains("no source")),
                "list {outside} must not resolve, got {:?}",
                result.lines
            );
        }
        // An address inside an instruction still resolves, including one that
        // lands part-way through the two-byte instruction at 0x10.
        for inside in ["10", "11"] {
            let result = console.command(&format!("list {inside}"), None);
            assert!(
                result.lines.iter().any(|line| line.contains("app.s:7")),
                "list {inside} must resolve, got {:?}",
                result.lines
            );
        }
    }

    #[test]
    fn disassembling_outside_the_image_says_so_instead_of_printing_nothing() {
        let mut console = DebugConsole::new(Some(map()));
        console.response(&[1, 0x56, 0x34, 0x12]);
        // An operator reaches an address like this by pasting the program
        // counter `regs` reports for an endpoint that has already exited.
        let result = console.command("dis fee7db 20", None);
        assert!(
            result.lines.iter().any(|line| line.contains("fee7db")),
            "an empty range must be reported, got {:?}",
            result.lines
        );
        // A real range still disassembles.
        let good = console.command("dis 10 2", None);
        assert!(
            good.lines.iter().any(|line| line.contains("lc r0,1")),
            "valid range must still disassemble, got {:?}",
            good.lines
        );
    }

    fn map() -> DebugMap {
        DebugMap {
            format: "swtos-debug-v1".into(),
            build_id: "crc24:123456".into(),
            build_id_size: 32,
            image_sha256: "00".repeat(32),
            image_size: 64,
            symbols: vec![Symbol {
                name: "counter".into(),
                address: 0x10,
                module: "app".into(),
            }],
            functions: vec![Function {
                name: "counter".into(),
                address: 0x10,
                end: 0x13,
                module: "app".into(),
            }],
            instructions: vec![
                Instruction {
                    address: 0x10,
                    size: 2,
                    bytes: "4401".into(),
                    text: "lc r0,1".into(),
                    source: "app.s".into(),
                    line: 7,
                },
                Instruction {
                    address: 0x12,
                    size: 1,
                    bytes: "28".into(),
                    text: "jmp (r2)".into(),
                    source: "app.s".into(),
                    line: 8,
                },
            ],
        }
    }

    #[test]
    fn resolves_symbols_source_and_instructions() {
        let map = map();
        assert_eq!(map.symbol("counter").unwrap().address, 0x10);
        assert_eq!(map.source_at(0x11).unwrap().line, 7);
        assert_eq!(map.disassemble(0x10, 2).len(), 2);
    }

    #[test]
    fn rejects_mismatch_but_raw_request_codecs_remain_available() {
        let map = map();
        assert!(map.require_match(0x123456).is_ok());
        assert!(
            map.require_match(0x654321)
                .unwrap_err()
                .contains("mismatch")
        );
        assert_eq!(registers_request(2), [2, 2]);
        assert_eq!(
            memory_request(0x123456, 4).unwrap(),
            [3, 0x56, 0x34, 0x12, 4]
        );
    }

    #[test]
    fn symbolic_commands_require_a_matching_build_but_raw_commands_do_not() {
        let mut console = DebugConsole::new(Some(map()));
        assert!(console.command("sym counter", None).lines[0].contains("not received"));
        console.response(&[1, 0x21, 0x43, 0x65]);
        assert!(console.command("sym counter", None).lines[0].contains("mismatch"));
        assert_eq!(console.command("regs 2", None).request, Some(vec![2, 2]));
        console.response(&[1, 0x56, 0x34, 0x12]);
        assert!(console.command("sym counter", None).lines[0].contains("000010"));
        assert_eq!(
            console.command("list counter", None).lines[0],
            "000010 app.s:7 lc r0,1"
        );
        assert_eq!(console.command("dis counter 2", None).lines.len(), 2);
        assert_eq!(
            console.command("break counter", None).request,
            Some(vec![6, 0x10, 0, 0])
        );
        assert_eq!(
            console.command("break app.s:8", None).request,
            Some(vec![6, 0x12, 0, 0])
        );
        assert_eq!(
            console.command("delete 0x10", None).request,
            Some(vec![7, 0x10, 0, 0])
        );
        assert_eq!(console.command("next", None).request, Some(vec![10]));
        assert_eq!(
            console.response(&[8, 1, 0x10, 0, 0]),
            vec!["1: 000010 counter"]
        );
    }
}
