//! Fixed four-pane terminal desktop used by the SWTOS framed frontend.

use std::collections::VecDeque;

pub const PANE_COUNT: usize = 4;
pub const DEFAULT_SCROLLBACK: usize = 1_000;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PaneKind {
    Shell,
    Application,
    Debugger,
    Resources,
}

impl PaneKind {
    pub const ALL: [Self; PANE_COUNT] = [
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

    pub fn channel(self) -> u8 {
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
    lines: VecDeque<String>,
    current: String,
    scrollback_limit: usize,
}

impl Pane {
    fn new(kind: PaneKind, scrollback_limit: usize) -> Self {
        Self {
            kind,
            lines: VecDeque::new(),
            current: String::new(),
            scrollback_limit,
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
        let start = self.lines.len().saturating_sub(complete);
        let mut output: Vec<&str> = self.lines.range(start..).map(String::as_str).collect();
        if !self.current.is_empty() && output.len() < height {
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
}

pub struct Desktop {
    panes: [Pane; PANE_COUNT],
    focus: usize,
    zoomed: bool,
    help: bool,
    connected: bool,
    clock: String,
    error: Option<String>,
}

impl Default for Desktop {
    fn default() -> Self {
        Self::new(DEFAULT_SCROLLBACK)
    }
}

impl Desktop {
    pub fn new(scrollback_limit: usize) -> Self {
        Self {
            panes: PaneKind::ALL.map(|kind| Pane::new(kind, scrollback_limit)),
            focus: 0,
            zoomed: false,
            help: false,
            connected: true,
            clock: "--:--:--".into(),
            error: None,
        }
    }

    pub fn focused_kind(&self) -> PaneKind {
        self.panes[self.focus].kind
    }

    pub fn focused_channel(&self) -> u8 {
        self.focused_kind().channel()
    }

    pub fn push_channel(&mut self, channel: u8, bytes: &[u8]) {
        if let Some(pane) = self
            .panes
            .iter_mut()
            .find(|pane| pane.kind.channel() == channel)
        {
            pane.push(bytes);
        }
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
        match byte {
            b'1'..=b'4' => self.focus = usize::from(byte - b'1'),
            b'n' | b'\t' => self.focus = (self.focus + 1) % PANE_COUNT,
            b'z' => self.zoomed = !self.zoomed,
            b'?' | b'h' => self.help = !self.help,
            b'd' | 0x04 => return CommandOutcome::Detach,
            _ => {}
        }
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
                0,
                0,
                width,
                body_height,
                "Help",
                &[
                    "1-4 focus  n next  z zoom",
                    "? help  d detach  prefix prefix",
                ],
                true,
            );
        } else if self.zoomed {
            self.draw_pane(&mut canvas, self.focus, 0, 0, width, body_height);
        } else {
            let left = width / 2;
            let top = body_height / 2;
            self.draw_pane(&mut canvas, 0, 0, 0, left, top);
            self.draw_pane(&mut canvas, 1, left, 0, width - left, top);
            self.draw_pane(&mut canvas, 2, 0, top, left, body_height - top);
            self.draw_pane(&mut canvas, 3, left, top, width - left, body_height - top);
        }

        let mut output = String::from("\x1b[H");
        for row in canvas {
            output.extend(row);
            output.push_str("\x1b[K\r\n");
        }
        let error = self.error.as_deref().unwrap_or("ok");
        let status = format!(
            " focus:{}  prefix help  {}  clock:{}  {}",
            self.focused_kind().title(),
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
        draw_box(
            canvas,
            x,
            y,
            width,
            height,
            self.panes[index].kind.title(),
            &lines,
            index == self.focus,
        );
    }
}

fn draw_box(
    canvas: &mut [Vec<char>],
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    title: &str,
    lines: &[&str],
    focused: bool,
) {
    if width < 2 || height < 2 || y >= canvas.len() {
        return;
    }
    let right = (x + width - 1).min(canvas[0].len() - 1);
    let bottom = (y + height - 1).min(canvas.len() - 1);
    for column in x..=right {
        canvas[y][column] = if column == x || column == right {
            '+'
        } else {
            '-'
        };
        canvas[bottom][column] = if column == x || column == right {
            '+'
        } else {
            '-'
        };
    }
    for row in y + 1..bottom {
        canvas[row][x] = '|';
        canvas[row][right] = '|';
    }
    let label = format!(" {}{} ", title, if focused { " *" } else { "" });
    for (offset, character) in label.chars().take(width.saturating_sub(2)).enumerate() {
        canvas[y][x + 1 + offset] = character;
    }
    for (row, line) in lines.iter().take(bottom.saturating_sub(y + 1)).enumerate() {
        for (column, character) in line.chars().take(width.saturating_sub(2)).enumerate() {
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
        assert!(help.contains("1-4 focus"));
    }
}
