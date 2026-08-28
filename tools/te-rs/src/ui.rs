//! Dynamic terminal desktop used by the SWTOS framed frontend.

use serde::{Deserialize, Serialize};
use std::collections::VecDeque;

pub const DEFAULT_SCROLLBACK: usize = 1_000;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum PaneKind {
    Shell,
    Application,
    Debugger,
    Resources,
}

impl PaneKind {
    pub const ALL: [Self; 4] = [
        Self::Shell,
        Self::Application,
        Self::Debugger,
        Self::Resources,
    ];

    pub fn title(self) -> &'static str {
        match self {
            Self::Shell => "Shell",
            Self::Application => "Application",
            Self::Debugger => "Debugger",
            Self::Resources => "Resources",
        }
    }

    pub fn default_channel(self) -> u8 {
        match self {
            Self::Shell => 0,
            Self::Application => 1,
            Self::Debugger => 254,
            Self::Resources => 255,
        }
    }
}

#[derive(Debug)]
pub struct Pane {
    pub kind: PaneKind,
    pub channel: u8,
    pub title: String,
    lines: VecDeque<String>,
    current: String,
    scrollback_limit: usize,
    alert: bool,
    scroll_offset: usize,
    horizontal_offset: usize,
    search: Option<String>,
}

impl Pane {
    fn new(kind: PaneKind, channel: u8, title: impl Into<String>, scrollback_limit: usize) -> Self {
        Self {
            kind,
            channel,
            title: title.into(),
            lines: VecDeque::new(),
            current: String::new(),
            scrollback_limit,
            alert: false,
            scroll_offset: 0,
            horizontal_offset: 0,
            search: None,
        }
    }

    pub fn push(&mut self, bytes: &[u8]) {
        for &byte in bytes {
            match byte {
                b'\n' => self.finish_line(),
                b'\r' => self.current.clear(),
                0x08 | 0x7f => {
                    self.current.pop();
                }
                0x20..=0x7e => self.current.push(char::from(byte)),
                _ => self.current.push('�'),
            }
        }
    }

    fn finish_line(&mut self) {
        self.lines.push_back(std::mem::take(&mut self.current));
        while self.lines.len() > self.scrollback_limit {
            self.lines.pop_front();
        }
    }

    fn visible_lines(&self, height: usize) -> Vec<&str> {
        let complete = height.saturating_sub(usize::from(!self.current.is_empty()));
        let end = self.lines.len().saturating_sub(self.scroll_offset);
        let start = end.saturating_sub(complete);
        let mut output: Vec<&str> = self.lines.range(start..end).map(String::as_str).collect();
        if self.scroll_offset == 0 && !self.current.is_empty() && output.len() < height {
            output.push(&self.current);
        }
        output
    }

    fn replace(&mut self, lines: &[String]) {
        self.lines.clear();
        self.current.clear();
        for line in lines {
            self.lines.push_back(line.clone());
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CommandOutcome {
    Continue,
    Detach,
    Save,
}

pub struct Desktop {
    panes: Vec<Pane>,
    focus: usize,
    zoomed: bool,
    help: bool,
    connected: bool,
    clock: String,
    error: Option<String>,
    copy_mode: bool,
    broadcast: bool,
    broadcast_armed: bool,
}

impl Default for Desktop {
    fn default() -> Self {
        Self::new(DEFAULT_SCROLLBACK)
    }
}

impl Desktop {
    pub fn new(scrollback_limit: usize) -> Self {
        Self {
            panes: PaneKind::ALL
                .into_iter()
                .map(|kind| Pane::new(kind, kind.default_channel(), kind.title(), scrollback_limit))
                .collect(),
            focus: 0,
            zoomed: false,
            help: false,
            connected: true,
            clock: "--:--:--".into(),
            error: None,
            copy_mode: false,
            broadcast: false,
            broadcast_armed: false,
        }
    }

    pub fn focused_kind(&self) -> PaneKind {
        self.panes[self.focus].kind
    }

    pub fn focused_channel(&self) -> u8 {
        self.panes[self.focus].channel
    }

    pub fn assign_focused(&mut self, channel: u8, title: impl Into<String>) {
        let pane = &mut self.panes[self.focus];
        pane.channel = channel;
        pane.title = title.into();
        pane.kind = PaneKind::Application;
    }

    pub fn set_channel_title(&mut self, channel: u8, title: impl Into<String>) {
        if let Some(pane) = self.panes.iter_mut().find(|pane| pane.channel == channel) {
            pane.title = title.into();
        }
    }

    /// Reserve the next application TTY without stealing keyboard focus.
    /// Channel 1 is pre-created and corresponds to process endpoint 2.
    pub fn claim_application(&mut self, title: impl Into<String>) -> Option<u8> {
        let title = title.into();
        if let Some(pane) = self
            .panes
            .iter_mut()
            .find(|pane| pane.kind == PaneKind::Application && pane.title == "Application")
        {
            pane.title = title;
            return Some(pane.channel);
        }
        let used = self
            .panes
            .iter()
            .map(|pane| pane.channel)
            .collect::<Vec<_>>();
        let channel = (1..=253).find(|channel| !used.contains(channel))?;
        self.panes.push(Pane::new(
            PaneKind::Application,
            channel,
            title,
            DEFAULT_SCROLLBACK,
        ));
        Some(channel)
    }

    pub fn pane_count(&self) -> usize {
        self.panes.len()
    }
    pub fn has_channel(&self, channel: u8) -> bool {
        self.panes.iter().any(|pane| pane.channel == channel)
    }
    pub fn broadcast_enabled(&self) -> bool {
        self.broadcast
    }
    pub fn copy_mode_enabled(&self) -> bool {
        self.copy_mode
    }

    pub fn help_enabled(&self) -> bool {
        self.help
    }

    pub fn copy_move(&mut self, vertical: isize, horizontal: isize) {
        let pane = &mut self.panes[self.focus];
        pane.scroll_offset = pane
            .scroll_offset
            .saturating_add_signed(vertical)
            .min(pane.lines.len());
        pane.horizontal_offset = pane.horizontal_offset.saturating_add_signed(horizontal);
    }

    pub fn copy_home(&mut self) {
        let pane = &mut self.panes[self.focus];
        pane.scroll_offset = pane.lines.len();
        pane.horizontal_offset = 0;
    }

    pub fn copy_end(&mut self) {
        let pane = &mut self.panes[self.focus];
        pane.scroll_offset = 0;
        pane.horizontal_offset = 0;
    }
    pub fn input_channels(&self) -> Vec<u8> {
        if self.broadcast {
            self.panes
                .iter()
                .filter(|pane| matches!(pane.kind, PaneKind::Shell | PaneKind::Application))
                .map(|pane| pane.channel)
                .collect()
        } else {
            vec![self.focused_channel()]
        }
    }

    pub fn push_channel(&mut self, channel: u8, bytes: &[u8]) {
        if let Some(index) = self.panes.iter().position(|pane| pane.channel == channel) {
            let pane = &mut self.panes[index];
            pane.push(bytes);
            if index != self.focus {
                pane.alert = true;
            }
        }
    }

    pub fn add_application(&mut self, channel: u8, title: impl Into<String>) -> usize {
        if let Some(index) = self.panes.iter().position(|pane| pane.channel == channel) {
            self.panes[index].title = title.into();
            self.focus = index;
            return index;
        }
        self.panes.push(Pane::new(
            PaneKind::Application,
            channel,
            title,
            DEFAULT_SCROLLBACK,
        ));
        self.focus = self.panes.len() - 1;
        self.focus
    }

    pub fn close_focused(&mut self) {
        if self.panes.len() > 1 {
            self.panes.remove(self.focus);
            self.focus = self.focus.min(self.panes.len() - 1);
        }
    }

    pub fn release_channel(&mut self, channel: u8) {
        self.panes.retain(|pane| {
            pane.channel != channel
                || matches!(
                    pane.kind,
                    PaneKind::Shell | PaneKind::Debugger | PaneKind::Resources
                )
        });
        self.focus = self.focus.min(self.panes.len().saturating_sub(1));
    }

    pub fn search(&mut self, needle: &str) -> bool {
        let pane = &mut self.panes[self.focus];
        pane.search = Some(needle.into());
        if let Some(index) = pane.lines.iter().rposition(|line| line.contains(needle)) {
            pane.scroll_offset = pane.lines.len().saturating_sub(index + 1);
            true
        } else {
            false
        }
    }

    pub fn layout(&self) -> Vec<(PaneKind, u8, String)> {
        self.panes
            .iter()
            .map(|pane| (pane.kind, pane.channel, pane.title.clone()))
            .collect()
    }

    pub fn restore_layout(&mut self, layout: &[(PaneKind, u8, String)]) {
        if layout.is_empty() {
            return;
        }
        self.panes = layout
            .iter()
            .map(|(kind, channel, title)| Pane::new(*kind, *channel, title, DEFAULT_SCROLLBACK))
            .collect();
        self.focus = 0;
    }

    pub fn set_connected(&mut self, connected: bool) {
        self.connected = connected;
    }

    pub fn set_clock(&mut self, value: impl Into<String>) {
        self.clock = value.into();
    }

    pub fn set_error(&mut self, value: Option<String>) {
        self.error = value;
    }

    pub fn set_resources(&mut self, lines: &[String]) {
        if let Some(pane) = self
            .panes
            .iter_mut()
            .find(|pane| pane.kind == PaneKind::Resources)
        {
            pane.replace(lines);
        }
    }

    pub fn command(&mut self, byte: u8) -> CommandOutcome {
        if byte != b'b' {
            self.broadcast_armed = false;
        }
        match byte {
            b'1'..=b'9' if usize::from(byte - b'1') < self.panes.len() => {
                self.focus = usize::from(byte - b'1')
            }
            b'n' | b'\t' => self.focus = (self.focus + 1) % self.panes.len(),
            b'p' => self.focus = (self.focus + self.panes.len() - 1) % self.panes.len(),
            b'z' => {
                self.help = false;
                self.zoomed = !self.zoomed;
            }
            b'x' => self.close_focused(),
            b'y' => self.copy_mode = !self.copy_mode,
            b'w' => return CommandOutcome::Save,
            b'b' if self.broadcast_armed => {
                self.broadcast = !self.broadcast;
                self.broadcast_armed = false;
            }
            b'b' => self.broadcast_armed = true,
            0x1b | b'q' if self.help => self.help = false,
            0x1b => {
                self.broadcast_armed = false;
                self.broadcast = false;
                self.copy_mode = false;
            }
            b'?' | b'h' => self.help = !self.help,
            b'd' | 0x04 => return CommandOutcome::Detach,
            _ => {}
        }
        self.panes[self.focus].alert = false;
        CommandOutcome::Continue
    }

    pub fn render(&self, width: usize, height: usize) -> String {
        let width = width.max(24);
        let height = height.max(8);
        let body_height = height.saturating_sub(2);
        let mut canvas = vec![vec![' '; width]; body_height];

        if self.help {
            draw_box(
                &mut canvas,
                BoxSpec {
                    x: 0,
                    y: 0,
                    width,
                    height: body_height,
                    title: "Help",
                    lines: &[
                        "1-9 focus  n next  p previous  z zoom  s split  x close",
                        "y copy  b,b broadcast  w save  R restore-layout",
                        "copy: arrows/hjkl  PgUp/PgDn  g/G  q exit",
                        "r reconnect/redraw  e target-Escape  ? help  d detach",
                        "close help: q, Escape, or ?",
                    ],
                    horizontal_offset: 0,
                    focused: true,
                },
            );
        } else if self.zoomed {
            self.draw_pane(&mut canvas, self.focus, 0, 0, width, body_height);
        } else {
            let columns = if self.panes.len() <= 1 { 1 } else { 2 };
            let rows = self.panes.len().div_ceil(columns);
            for index in 0..self.panes.len() {
                let column = index % columns;
                let row = index / columns;
                let x = column * width / columns;
                let next_x = (column + 1) * width / columns;
                let y = row * body_height / rows;
                let next_y = (row + 1) * body_height / rows;
                self.draw_pane(&mut canvas, index, x, y, next_x - x, next_y - y);
            }
        }

        let mut output = String::from("\x1b[H");
        for row in canvas {
            output.extend(row);
            output.push_str("\x1b[K\r\n");
        }
        let error = self.error.as_deref().unwrap_or("ok");
        let status = format!(
            " focus:{}  panes:{}{}{}  {}  clock:{}  {}",
            self.panes[self.focus].title,
            self.panes.len(),
            if self.broadcast {
                " BROADCAST"
            } else if self.broadcast_armed {
                " broadcast?"
            } else {
                ""
            },
            if self.copy_mode { " COPY" } else { "" },
            if self.connected {
                "connected"
            } else {
                "disconnected"
            },
            self.clock,
            error
        );
        output.push_str(&truncate(&status, width));
        output.push_str("\x1b[K\r\n");
        output
    }

    fn draw_pane(
        &self,
        canvas: &mut [Vec<char>],
        index: usize,
        x: usize,
        y: usize,
        width: usize,
        height: usize,
    ) {
        let content_height = height.saturating_sub(2);
        let lines = self.panes[index].visible_lines(content_height);
        let horizontal_offset = self.panes[index].horizontal_offset;
        let title = format!(
            "{}{}",
            self.panes[index].title,
            if self.panes[index].alert { " !" } else { "" }
        );
        draw_box(
            canvas,
            BoxSpec {
                x,
                y,
                width,
                height,
                title: &title,
                lines: &lines,
                horizontal_offset,
                focused: index == self.focus,
            },
        );
    }
}

/// Where a box goes and what it holds.
struct BoxSpec<'a> {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    title: &'a str,
    lines: &'a [&'a str],
    horizontal_offset: usize,
    focused: bool,
}

fn draw_box(canvas: &mut [Vec<char>], spec: BoxSpec<'_>) {
    let BoxSpec {
        x,
        y,
        width,
        height,
        title,
        lines,
        horizontal_offset,
        focused,
    } = spec;
    if width < 2 || height < 2 || y >= canvas.len() {
        return;
    }
    let right = (x + width - 1).min(canvas[0].len() - 1);
    let bottom = (y + height - 1).min(canvas.len() - 1);
    // The top and bottom edges are identical, so build the run once and copy
    // it into both rows. This also keeps working when the box is clamped flat
    // and the two edges are the same row.
    let mut edge = vec!['-'; right + 1 - x];
    edge[0] = '+';
    if let Some(last) = edge.last_mut() {
        *last = '+';
    }
    canvas[y][x..=right].copy_from_slice(&edge);
    canvas[bottom][x..=right].copy_from_slice(&edge);
    for row in canvas.iter_mut().take(bottom).skip(y + 1) {
        row[x] = '|';
        row[right] = '|';
    }
    let label = format!(" {}{} ", title, if focused { " *" } else { "" });
    for (offset, character) in label.chars().take(width.saturating_sub(2)).enumerate() {
        canvas[y][x + 1 + offset] = character;
    }
    for (row, line) in lines.iter().take(bottom.saturating_sub(y + 1)).enumerate() {
        for (column, character) in line
            .chars()
            .skip(horizontal_offset)
            .take(width.saturating_sub(2))
            .enumerate()
        {
            canvas[y + 1 + row][x + 1 + column] = character;
        }
    }
}

fn truncate(value: &str, width: usize) -> String {
    value.chars().take(width).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn focus_routes_channels_and_commands() {
        let mut desktop = Desktop::default();
        assert_eq!(desktop.focused_channel(), 0);
        desktop.command(b'2');
        assert_eq!(desktop.focused_channel(), 1);
        desktop.command(b'n');
        assert_eq!(desktop.focused_kind(), PaneKind::Debugger);
        desktop.command(b'4');
        assert_eq!(desktop.focused_kind(), PaneKind::Resources);
        assert_eq!(desktop.command(b'd'), CommandOutcome::Detach);
    }

    #[test]
    fn panes_keep_independent_bounded_scrollback_and_resize() {
        let mut desktop = Desktop::new(2);
        desktop.push_channel(0, b"old\nmiddle\nshell\ntail");
        desktop.push_channel(1, b"application\n");
        let large = desktop.render(80, 24);
        assert!(!large.contains("old"));
        assert!(large.contains("shell"));
        assert!(large.contains("tail"));
        assert!(large.contains("application"));
        let small = desktop.render(40, 12);
        assert!(small.contains("Shell *"));
        assert!(small.contains("Resources"));
    }

    #[test]
    fn zoom_and_help_replace_the_grid() {
        let mut desktop = Desktop::default();
        desktop.command(b'z');
        let zoomed = desktop.render(60, 16);
        assert!(zoomed.contains("Shell *"));
        assert!(!zoomed.contains("Application"));
        desktop.command(b'?');
        let help = desktop.render(60, 16);
        assert!(help.contains("1-9 focus"));
        desktop.command(b'q');
        assert!(!desktop.help_enabled());
        assert!(desktop.render(60, 16).contains("Shell *"));
    }

    #[test]
    fn background_application_claims_tty_without_stealing_shell_focus() {
        let mut desktop = Desktop::default();
        assert_eq!(desktop.claim_application("cpu-hog"), Some(1));
        assert_eq!(desktop.focused_kind(), PaneKind::Shell);
        assert_eq!(desktop.claim_application("cpu-hog"), Some(2));
        assert_eq!(desktop.focused_kind(), PaneKind::Shell);
        assert!(desktop.has_channel(1));
        assert!(desktop.has_channel(2));
    }

    #[test]
    fn dynamic_layout_search_alerts_and_guarded_broadcast() {
        let mut desktop = Desktop::default();
        desktop.add_application(7, "Counter");
        assert_eq!(desktop.pane_count(), 5);
        desktop.command(b'1');
        desktop.push_channel(7, b"count 1\ncount 2\n");
        assert!(desktop.render(80, 24).contains("Counter !"));
        desktop.command(b'5');
        assert!(desktop.search("count 1"));
        assert!(!desktop.broadcast_enabled());
        desktop.command(b'b');
        desktop.command(b'1');
        desktop.command(b'b');
        assert!(!desktop.broadcast_enabled());
        desktop.command(b'b');
        assert!(desktop.broadcast_enabled());
        assert_eq!(desktop.input_channels(), vec![0, 1, 7]);
        let saved = desktop.layout();
        desktop.close_focused();
        desktop.restore_layout(&saved);
        assert_eq!(desktop.pane_count(), 5);
        desktop.release_channel(7);
        assert_eq!(desktop.pane_count(), 4);
    }

    #[test]
    fn copy_mode_scrolls_vertically_and_horizontally() {
        let mut desktop = Desktop::new(10);
        desktop.push_channel(0, b"zero\none\ntwo\n0123456789abcdef\n");
        desktop.command(b'y');
        assert!(desktop.copy_mode_enabled());
        desktop.command(b'z');
        desktop.copy_move(0, 5);
        assert_eq!(desktop.panes[0].horizontal_offset, 5);
        assert!(desktop.render(24, 8).contains("56789abcdef"));
        desktop.copy_move(1, 0);
        assert_eq!(desktop.panes[0].scroll_offset, 1);
        desktop.copy_home();
        assert_eq!(desktop.panes[0].scroll_offset, 4);
        assert_eq!(desktop.panes[0].horizontal_offset, 0);
        desktop.copy_end();
        assert_eq!(desktop.panes[0].scroll_offset, 0);
    }
}
