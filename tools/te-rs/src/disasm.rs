//! Decode COR24 instructions from bytes alone.
//!
//! The debugger's `dis` reads its answers from the build's debug map, which
//! covers only the statically linked image. A spawned process runs a private
//! copy of a catalog image somewhere in the arena, and its program counter is
//! an address the map has never heard of, so `dis` refused exactly where a
//! person most wants it.
//!
//! Decoding needs no map. The ISA crate encodes every instruction, so
//! inverting its encoders gives a complete table from opcode byte back to the
//! instruction, exact by construction rather than by a second table written
//! out by hand and left to drift.

use cor24_isa::opcode::{InstructionFormat, Opcode};
use cor24_isa::encode::encode_instruction;

/// One decoded instruction: its text and how many bytes it occupied.
pub struct Decoded {
    pub text: String,
    pub size: usize,
}

/// Opcode byte -> (opcode, ra, rb), built by inverting the encoders.
fn table() -> [Option<(Opcode, u8, u8)>; 256] {
    let mut table: [Option<(Opcode, u8, u8)>; 256] = [None; 256];
    // Every opcode value the ISA knows; From<u8> maps the rest to Invalid,
    // which encodes nothing and so leaves its slots empty.
    for value in 0..=0x1Fu8 {
        let opcode = Opcode::from(value);
        for ra in 0..8 {
            for rb in 0..8 {
                if let Some(byte) = encode_instruction(opcode, ra, rb) {
                    // First writer wins: an opcode that ignores a register
                    // encodes the same byte for every value of it, and the
                    // zero case is the one to report.
                    table[usize::from(byte)].get_or_insert((opcode, ra, rb));
                }
            }
        }
    }
    table
}


/// The ISA crate's own names, so the two cannot drift apart.
fn register(index: u8) -> &'static str {
    cor24_isa::register::reg_name(index)
}

/// Decode one instruction from `bytes`, which begins at the instruction.
///
/// `address` is where that instruction lives, which a branch needs: the
/// encoding holds a displacement and a reader wants somewhere to look.
///
/// Returns None when there are not enough bytes for the instruction the first
/// one starts, so a caller reading a fixed window stops cleanly at its end.
pub fn decode(bytes: &[u8], address: u32) -> Option<Decoded> {
    let first = *bytes.first()?;
    let (opcode, ra, rb) = table()[usize::from(first)]?;
    let size = opcode.format().size();
    if bytes.len() < size {
        return None;
    }
    let mnemonic = opcode.mnemonic();
    let text = match opcode.format() {
        InstructionFormat::SingleByte => match opcode {
            Opcode::Push | Opcode::Pop => format!("{mnemonic} {}", register(ra)),
            // An indirect operand is written in parentheses, as the assembler
            // writes it and as anyone reading it back would type it.
            Opcode::Jmp => format!("{mnemonic} ({})", register(ra)),
            Opcode::Jal => format!("{mnemonic} {},({})", register(ra), register(rb)),
            Opcode::SubSp => "sub sp,r0".to_string(),
            _ => format!("{mnemonic} {},{}", register(ra), register(rb)),
        },
        InstructionFormat::TwoBytes => {
            let operand = bytes[1];
            match opcode {
                // A branch carries a displacement from the instruction after
                // it; report where it lands, which is what a reader wants.
                Opcode::Bra | Opcode::Brf | Opcode::Brt => {
                    let target = address
                        .wrapping_add(size as u32)
                        .wrapping_add(operand as i8 as i32 as u32)
                        & 0x00FF_FFFF;
                    format!("{mnemonic} 0x{target:06X}")
                }
                Opcode::Lc => format!("{mnemonic} {},{}", register(ra), operand as i8),
                Opcode::Lcu => format!("{mnemonic} {},{operand}", register(ra)),
                // The add immediate is a signed byte, which is the whole
                // reason 128..255 assemble quietly and run as negatives.
                Opcode::AddImm => format!("{mnemonic} {},{}", register(ra), operand as i8),
                _ => format!("{mnemonic} {},{}({})", register(ra), operand as i8, register(rb)),
            }
        }
        InstructionFormat::FourBytes => {
            let address = u32::from(bytes[1])
                | u32::from(bytes[2]) << 8
                | u32::from(bytes[3]) << 16;
            format!("{mnemonic} {},0x{address:06X}", register(ra))
        }
    };
    Some(Decoded { text, size })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    /// Decode every instruction the linker emitted and check it against what
    /// the linker said it was. The build's debug map is the only oracle that
    /// covers the instruction set as actually generated, which is what proves
    /// this is a disassembler rather than a plausible-looking table.
    ///
    /// The map names its operands -- "brf _kernel_stack_fill", "la r0,L100" --
    /// and a decoder reading bytes has no symbols, so the comparison is on
    /// what decoding decides: the mnemonic, the length, and any operand the
    /// map wrote as a number.
    #[test]
    fn decodes_every_instruction_the_linker_emitted() {
        let map = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../build/scheduled-shell/program.debug.json");
        let Ok(text) = std::fs::read_to_string(&map) else {
            eprintln!("skipping: {} has not been built", map.display());
            return;
        };
        let document: serde_json::Value = serde_json::from_str(&text).expect("debug map is JSON");
        let instructions = document["instructions"].as_array().expect("instruction list");
        let mut checked = 0;
        let mut wrong: Vec<String> = Vec::new();
        for entry in instructions {
            let raw = entry["bytes"].as_str().expect("instruction bytes");
            let bytes: Vec<u8> = (0..raw.len() / 2)
                .map(|index| u8::from_str_radix(&raw[index * 2..index * 2 + 2], 16).unwrap())
                .collect();
            let address = entry["address"].as_u64().unwrap() as u32;
            let size = entry["size"].as_u64().unwrap() as usize;
            let expected = entry["text"].as_str().unwrap();
            // The map lists data words among the instructions. Decoding those
            // is meaningless: they are not code, whatever their bytes spell.
            if expected.trim_start().starts_with('.') {
                continue;
            }
            let mut words = expected.split_whitespace();
            let want_mnemonic = words.next().unwrap_or("").to_lowercase();
            let want_operands = words.next().unwrap_or("");

            let Some(decoded) = decode(&bytes, address) else {
                wrong.push(format!("{raw} at {address:06x} did not decode"));
                continue;
            };
            checked += 1;
            let mut got = decoded.text.split_whitespace();
            let got_mnemonic = got.next().unwrap_or("").to_lowercase();
            let got_operands = got.next().unwrap_or("");
            if got_mnemonic != want_mnemonic || decoded.size != size {
                if wrong.len() < 12 {
                    wrong.push(format!(
                        "{raw} -> {:?}/{} want {:?}/{size}",
                        decoded.text, decoded.size, expected
                    ));
                }
                continue;
            }
            // Operands only where the linker wrote numbers rather than names.
            let symbolic = want_operands.contains('_')
                || want_operands.split(',').next_back().is_some_and(|last| {
                    last.starts_with('L') && last[1..].chars().all(|c| c.is_ascii_digit())
                });
            // The assembler writes register five "c" in some listings and
            // "z" in others, and prints a negative address as a decimal
            // rather than its 24-bit pattern. Neither is a decoding question.
            let want_operands = &want_operands.replace(",c", ",z");
            if !symbolic && got_operands.to_lowercase() != want_operands.to_lowercase() {
                let numeric_match = numeric_tail(want_operands)
                    .zip(numeric_tail(got_operands))
                    .is_some_and(|(want, got)| (want & 0xFF_FFFF) == (got & 0xFF_FFFF));
                if !numeric_match && wrong.len() < 12 {
                    wrong.push(format!("{raw} -> {got_operands:?} want {want_operands:?}"));
                }
            }
        }
        assert!(checked > 1000, "expected a substantial image, decoded {checked}");
        assert!(
            wrong.is_empty(),
            "{} of {checked} disagreed:\n{}",
            wrong.len(),
            wrong.join("\n")
        );
    }

    /// The value of the last operand, when it is written as one.
    fn numeric_tail(operands: &str) -> Option<i64> {
        let last = operands.split(',').next_back()?.trim_end_matches(')');
        let last = last.rsplit('(').next()?;
        if let Some(hex) = last.strip_prefix("0x").or_else(|| last.strip_prefix("0X")) {
            i64::from_str_radix(hex, 16).ok()
        } else {
            last.parse::<i64>().ok()
        }
    }
}
