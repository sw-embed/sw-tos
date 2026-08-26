//! Build-matched symbolic inspection for COR24 debug artifacts.

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

    pub fn source_at(&self, address: u32) -> Option<&Instruction> {
        self.instructions
            .iter()
            .rev()
            .find(|instruction| instruction.address <= address)
    }

    pub fn disassemble(&self, address: u32, count: usize) -> Vec<&Instruction> {
        self.instructions
            .iter()
            .filter(|instruction| instruction.address >= address)
            .take(count)
            .collect()
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
            _ => vec!["invalid debug response".into()],
        }
    }

    pub fn command(&self, line: &str) -> CommandResult {
        let words: Vec<&str> = line.split_whitespace().collect();
        let result = match words.as_slice() {
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
            ["bl"] => Ok(text("breakpoints: none")),
            ["delete", _] => Ok(text(
                "no breakpoint exists (execution control arrives in Saga 8)",
            )),
            ["help"] | [] => Ok(text(
                "sym NAME | list LOC | dis LOC [N] | regs [EP] | x ADDR [N] | bl | delete N",
            )),
            _ => Err("unknown debugger command; use help".into()),
        };
        result.unwrap_or_else(|error| text(&error))
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
        if let Some(symbol) = self.matched_map()?.symbol(value) {
            return Ok(symbol.address);
        }
        parse_address(value)
    }

    fn list_command(&self, value: &str) -> Result<CommandResult, String> {
        let address = self.address(value)?;
        let instruction = self
            .matched_map()?
            .source_at(address)
            .ok_or_else(|| format!("no source for {address:06x}"))?;
        Ok(text(&format!(
            "{:06x} {}:{} {}",
            instruction.address, instruction.source, instruction.line, instruction.text
        )))
    }

    fn disassemble_command(&self, value: &str, count: usize) -> Result<CommandResult, String> {
        let address = self.address(value)?;
        let lines = self
            .matched_map()?
            .disassemble(address, count.min(32))
            .into_iter()
            .map(|item| format!("{:06x} {:<8} {}", item.address, item.bytes, item.text))
            .collect();
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
            functions: Vec::new(),
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
        assert!(console.command("sym counter").lines[0].contains("not received"));
        console.response(&[1, 0x21, 0x43, 0x65]);
        assert!(console.command("sym counter").lines[0].contains("mismatch"));
        assert_eq!(console.command("regs 2").request, Some(vec![2, 2]));
        console.response(&[1, 0x56, 0x34, 0x12]);
        assert!(console.command("sym counter").lines[0].contains("000010"));
        assert_eq!(
            console.command("list counter").lines[0],
            "000010 app.s:7 lc r0,1"
        );
        assert_eq!(console.command("dis counter 2").lines.len(), 2);
    }
}
