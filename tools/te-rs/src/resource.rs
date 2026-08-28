//! Assembly and rendering of bounded version-1 resource snapshot records.

use std::collections::BTreeMap;
use std::time::{Duration, Instant};

const BEGIN: u8 = 1;
const MEMORY: u8 = 2;
const PROCESS: u8 = 3;
const PROCESS_IO: u8 = 4;
const END: u8 = 5;
const PREEMPTION: u8 = 6;

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct MemorySnapshot {
    pub current: u32,
    pub peak: u32,
    pub kernel_stack_peak: u32,
    pub allocation_failures: u32,
    pub used_slots: u8,
    pub total_slots: u8,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ProcessSnapshot {
    pub endpoint: u8,
    pub state: u8,
    pub blocked: u8,
    pub stack_words: u16,
    pub state_words: u16,
    pub dispatches: u32,
    pub yields: u32,
    pub forced_preemptions: u32,
    pub cpu_progress: u32,
    pub ipc: u32,
    pub tty_in: u32,
    pub tty_out: u32,
    pub name: String,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ResourceSnapshot {
    pub generation: u8,
    pub memory: MemorySnapshot,
    pub processes: BTreeMap<u8, ProcessSnapshot>,
    pub protocol_errors: u32,
    pub uart_rx: u32,
    pub uart_tx: u32,
}

#[derive(Default)]
pub struct SnapshotAssembler {
    pending: Option<ResourceSnapshot>,
    current: Option<ResourceSnapshot>,
    updated: Option<Instant>,
}

impl SnapshotAssembler {
    pub fn push(&mut self, payload: &[u8], now: Instant) -> bool {
        let Some((&kind, rest)) = payload.split_first() else {
            return false;
        };
        let Some((&generation, body)) = rest.split_first() else {
            return false;
        };
        if kind == BEGIN {
            self.pending = Some(ResourceSnapshot {
                generation,
                ..ResourceSnapshot::default()
            });
            return false;
        }
        let Some(snapshot) = self.pending.as_mut().filter(|s| s.generation == generation) else {
            return false;
        };
        match kind {
            MEMORY if body.len() == 14 => {
                snapshot.memory = MemorySnapshot {
                    current: u24(&body[0..3]),
                    peak: u24(&body[3..6]),
                    kernel_stack_peak: u24(&body[6..9]),
                    allocation_failures: u24(&body[9..12]),
                    used_slots: body[12],
                    total_slots: body[13],
                };
            }
            PROCESS if body.len() == 13 => {
                let endpoint = body[0];
                let process = snapshot.processes.entry(endpoint).or_default();
                process.endpoint = endpoint;
                process.state = body[1];
                process.blocked = body[2];
                process.stack_words = u16::from_le_bytes([body[3], body[4]]);
                process.state_words = u16::from_le_bytes([body[5], body[6]]);
                process.dispatches = u24(&body[7..10]);
                process.yields = u24(&body[10..13]);
            }
            PROCESS_IO if body.len() == 14 => {
                let endpoint = body[0];
                let process = snapshot.processes.entry(endpoint).or_default();
                process.endpoint = endpoint;
                process.ipc = u24(&body[1..4]);
                process.tty_in = u24(&body[4..7]);
                process.tty_out = u24(&body[7..10]);
                process.name = String::from_utf8_lossy(&body[10..14])
                    .trim_end_matches('\0')
                    .to_string();
            }
            PREEMPTION if body.len() == 7 => {
                let endpoint = body[0];
                let process = snapshot.processes.entry(endpoint).or_default();
                process.endpoint = endpoint;
                process.forced_preemptions = u24(&body[1..4]);
                process.cpu_progress = u24(&body[4..7]);
            }
            END if body.len() == 9 => {
                snapshot.protocol_errors = u24(&body[0..3]);
                snapshot.uart_rx = u24(&body[3..6]);
                snapshot.uart_tx = u24(&body[6..9]);
                self.current = self.pending.take();
                self.updated = Some(now);
                return true;
            }
            _ => {}
        }
        false
    }

    pub fn snapshot(&self) -> Option<&ResourceSnapshot> {
        self.current.as_ref()
    }

    pub fn disconnect(&mut self) {
        self.pending = None;
        self.current = None;
        self.updated = None;
    }

    pub fn has_process_named(&self, prefix: &str) -> bool {
        self.current.as_ref().is_some_and(|snapshot| {
            snapshot
                .processes
                .values()
                .any(|process| process.name.starts_with(prefix))
        })
    }

    pub fn render(&self, now: Instant) -> Vec<String> {
        let Some(snapshot) = &self.current else {
            return vec!["resource data unavailable".into()];
        };
        let stale = self
            .updated
            .is_none_or(|updated| now.duration_since(updated) > Duration::from_secs(1));
        let marker = if stale { "STALE " } else { "" };
        let mut lines = vec![format!(
            "{marker}mem {}/{}B kstk={}B fail={} slots={}/{}",
            snapshot.memory.current,
            snapshot.memory.peak,
            snapshot.memory.kernel_stack_peak,
            snapshot.memory.allocation_failures,
            snapshot.memory.used_slots,
            snapshot.memory.total_slots
        )];
        for process in snapshot.processes.values() {
            lines.push(format!(
                "{} ep={} s={} b={} alloc={}/{}w d={} y={} fp={} cpu={} ipc={} io={}/{}",
                if process.name.is_empty() {
                    "-"
                } else {
                    &process.name
                },
                process.endpoint,
                process.state,
                process.blocked,
                process.stack_words,
                process.state_words,
                process.dispatches,
                process.yields,
                process.forced_preemptions,
                process.cpu_progress,
                process.ipc,
                process.tty_in,
                process.tty_out
            ));
        }
        lines.push(format!(
            "uart rx={} tx={} protocol-errors={}",
            snapshot.uart_rx, snapshot.uart_tx, snapshot.protocol_errors
        ));
        lines
    }
}

fn u24(bytes: &[u8]) -> u32 {
    u32::from(bytes[0]) | (u32::from(bytes[1]) << 8) | (u32::from(bytes[2]) << 16)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn commits_only_a_complete_matching_generation() {
        let now = Instant::now();
        let mut assembler = SnapshotAssembler::default();
        assembler.push(&[BEGIN, 7], now);
        assembler.push(
            &[MEMORY, 7, 10, 0, 0, 20, 0, 0, 3, 0, 0, 1, 0, 0, 2, 3],
            now,
        );
        assembler.push(&[PREEMPTION, 7, 2, 11, 0, 0, 42, 0, 0], now);
        assembler.push(&[PROCESS, 7, 2, 7, 1, 192, 0, 1, 0, 9, 0, 0, 4, 0, 0], now);
        assembler.push(
            &[
                PROCESS_IO, 7, 2, 3, 0, 0, 5, 0, 0, 6, 0, 0, b'c', b'n', b't', b'r',
            ],
            now,
        );
        assert!(!assembler.push(&[END, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0], now));
        assert!(assembler.push(&[END, 7, 2, 0, 0, 8, 0, 0, 9, 0, 0], now));
        let lines = assembler.render(now);
        assert!(lines.iter().any(|line| line.contains("mem 10/20B")));
        assert!(
            lines
                .iter()
                .any(|line| line.contains("cntr ep=2 s=7 b=1 alloc=192/1w d=9"))
        );
        assert!(lines.iter().any(|line| line.contains("fp=11")));
        assert!(lines.iter().any(|line| line.contains("cpu=42")));
    }

    #[test]
    fn stale_and_disconnected_are_not_valid_zeroes() {
        let now = Instant::now();
        let mut assembler = SnapshotAssembler::default();
        assert_eq!(assembler.render(now), ["resource data unavailable"]);
        assembler.push(&[BEGIN, 1], now);
        assembler.push(&[END, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0], now);
        assert!(assembler.render(now + Duration::from_secs(2))[0].starts_with("STALE"));
        assembler.disconnect();
        assert_eq!(assembler.render(now), ["resource data unavailable"]);
    }

    #[test]
    fn newer_generation_replaces_exited_rows_and_reclaimed_memory() {
        let now = Instant::now();
        let mut assembler = SnapshotAssembler::default();
        assembler.push(&[BEGIN, 1], now);
        assembler.push(
            &[MEMORY, 1, 30, 0, 0, 40, 0, 0, 2, 0, 0, 0, 0, 0, 3, 3],
            now,
        );
        assembler.push(
            &[
                PROCESS_IO, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, b'a', b'p', b'p', 0,
            ],
            now,
        );
        assembler.push(&[END, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0], now);
        assert!(
            assembler
                .render(now)
                .iter()
                .any(|line| line.contains("app ep=2"))
        );

        assembler.push(&[BEGIN, 2], now);
        assembler.push(
            &[MEMORY, 2, 10, 0, 0, 40, 0, 0, 2, 0, 0, 0, 0, 0, 1, 3],
            now,
        );
        assembler.push(&[END, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0], now);
        let lines = assembler.render(now);
        assert!(lines[0].contains("mem 10/40B"));
        assert!(!lines.iter().any(|line| line.contains("ep=2")));
    }
}
