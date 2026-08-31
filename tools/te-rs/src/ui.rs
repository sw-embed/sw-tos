//! Dynamic terminal desktop used by the SWTOS framed frontend.

use serde::{Deserialize, Serialize};
use std::collections::VecDeque;

pub const DEFAULT_SCROLLBACK: usize = 1_000;

/// Longest line a pane will accumulate before breaking it.
///
/// Completed lines are capped by the scrollback limit, but the line still
/// being assembled is not: a program that emits bytes and never a newline
/// would grow one pane without bound. Breaking the line keeps the output and
/// puts it under the scrollback limit, which is what a terminal does when it
/// wraps.
pub const MAX_LINE_BYTES: usize = 4_096;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum PaneKind {
    Shell,
    Application,
    Debugger,
    Resources,
}

impl PaneKind {
    /// Panes the frontend creates for itself.
    ///
    /// Resources is the frontend's own monitor, always present because it
    /// needs no slot and cannot be killed by accident. The `mon` program
    /// reports the same figures as an ordinary process, so several can run at
    /// once and any of them can be killed; this pane is the one that is
    /// simply always there.
    /// Panes the frontend creates for itself.
    ///
    /// There is no monitor pane: the monitor is the `mon` program, started at
    /// boot from the catalog's autostart list, so it holds an ordinary slot
    /// and an ordinary pane. A private pane drawing the same figures could
    /// not be killed, could not be run twice, and was a second renderer to
    /// keep in step with the first.
    pub const ALL: [Self; 3] = [Self::Shell, Self::Application, Self::Debugger];

    pub fn title(self) -> &'static str {
        match self {
            Self::Shell => "Shell",
            Self::Application => "Application",
            Self::Debugger => "Debugger",
            // Not "mon": that is the program, which holds a slot and can be
            // killed. Two things with one name on screen is one too many.
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
    /// A process held this channel at some point.
    ran: bool,
    /// That process has since gone.
    ended: bool,
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
            ran: false,
            ended: false,
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
                // Form feed clears the pane, so a program that redraws a whole
                // report each time replaces it instead of appending another
                // copy. Without this a monitor's output reads as a stuck
                // program whenever its figures hold still.
                0x0c => {
                    self.lines.clear();
                    self.current.clear();
                    self.scroll_offset = 0;
                }
                0x08 | 0x7f => {
                    self.current.pop();
                }
                0x20..=0x7e => self.current.push(char::from(byte)),
                _ => self.current.push('�'),
            }
            if self.current.len() >= MAX_LINE_BYTES {
                self.finish_line();
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

    /// Note which endpoints are running, so a pane whose process has gone
    /// says so instead of looking like one that simply has nothing to add.
    ///
    /// Only a pane that has held a process can end. The Application pane
    /// exists before anything runs on it, and an empty pane is not a dead
    /// one.
    pub fn mark_live_endpoints(&mut self, live: &[u8]) {
        for pane in &mut self.panes {
            if pane.kind != PaneKind::Application {
                continue;
            }
            let endpoint = u16::from(pane.channel) + 1;
            let running = u8::try_from(endpoint).is_ok_and(|value| live.contains(&value));
            if running {
                pane.ran = true;
                pane.ended = false;
            } else if pane.ran {
                pane.ended = true;
            }
        }
    }

    /// Close every pane whose process has ended, and return how many went.
    ///
    /// A long session leaves the grid full of finished programs, each taking
    /// a share of the screen from the ones still running.
    pub fn close_ended(&mut self) -> usize {
        let focused = self.panes.get(self.focus).map(|pane| pane.channel);
        let before = self.panes.len();
        self.panes.retain(|pane| !pane.ended);
        if self.panes.is_empty() {
            self.restore_system_panes();
        }
        self.focus = focused
            .and_then(|channel| self.panes.iter().position(|pane| pane.channel == channel))
            .unwrap_or(0);
        before - self.panes.len()
    }

    /// Name a pane after the process occupying its channel.
    ///
    /// A pane is opened before anything is known about what will speak on it,
    /// so it starts as "Application" or "TTY n". The resource snapshot names
    /// the process behind every endpoint, which is the only way a pane opened
    /// by a boot-time spawn ever learns what it is showing.
    pub fn name_channel(&mut self, channel: u8, title: &str) {
        if title.is_empty() {
            return;
        }
        for pane in &mut self.panes {
            if pane.channel == channel
                && pane.kind == PaneKind::Application
                && pane.title != title
            {
                pane.title = title.to_string();
            }
        }
    }

    /// Open (or rename) the pane for a channel, without taking focus.
    ///
    /// A new pane used to grab focus, which made launching two programs in a
    /// row impossible: the second command was typed into the first program's
    /// pane. Background means the prompt keeps the keyboard, so the pane
    /// appears and the user decides when to look at it.
    pub fn add_application(&mut self, channel: u8, title: impl Into<String>) -> usize {
        if let Some(index) = self.panes.iter().position(|pane| pane.channel == channel) {
            self.panes[index].title = title.into();
            return index;
        }
        self.panes.push(Pane::new(
            PaneKind::Application,
            channel,
            title,
            DEFAULT_SCROLLBACK,
        ));
        self.panes.len() - 1
    }

    /// Put back any system pane that has been closed.
    ///
    /// Ctrl-A x removes whatever holds focus, and closing Resources or the
    /// debugger was otherwise unrecoverable: reloading a saved layout is the
    /// only other route back and helps only if a layout was ever saved. Each
    /// missing pane returns at its canonical position, so the numbering a
    /// person has learned survives the accident.
    pub fn restore_system_panes(&mut self) -> usize {
        let mut restored = 0;
        for (position, kind) in PaneKind::ALL.into_iter().enumerate() {
            if self.panes.iter().any(|pane| pane.kind == kind) {
                continue;
            }
            let at = position.min(self.panes.len());
            self.panes.insert(
                at,
                Pane::new(kind, kind.default_channel(), kind.title(), DEFAULT_SCROLLBACK),
            );
            if self.focus >= at {
                self.focus += 1;
            }
            restored += 1;
        }
        restored
    }

    /// Empty a pane, keeping it open.
    ///
    /// A pane accumulates whatever its channel has ever said, which is not
    /// what a person wants when they start a new program on a channel some
    /// earlier one used, or when they simply want to read what happens next
    /// without the last hour above it.
    pub fn clear(&mut self, index: usize) {
        if let Some(pane) = self.panes.get_mut(index) {
            pane.lines.clear();
            pane.current.clear();
            pane.scroll_offset = 0;
            pane.alert = false;
        }
    }

    pub fn clear_channel(&mut self, channel: u8) {
        if let Some(index) = self.panes.iter().position(|pane| pane.channel == channel) {
            self.clear(index);
        }
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
            b'l' => self.clear(self.focus),
            b'S' => {
                self.restore_system_panes();
            }
            b'c' => {
                self.close_ended();
            }
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
                        "l clear pane  c close ended  S restore-system-panes",
                        "y copy",
                        "b,b broadcast",
                        "w save  R restore-layout",
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
            self.draw_grid(&mut canvas, width, body_height);
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

}

/// The tiling: how many rows and columns, and the width left for panes once
/// the column rules are taken out.
struct Grid {
    width: usize,
    columns: usize,
    column_total: usize,
    rows: usize,
}

impl Desktop {
    /// Tile the panes, sharing every edge.
    ///
    /// Boxing each pane separately spends two lines per row on borders and a
    /// column on each outer edge, which at nine rows costs half the display.
    /// Panes here share one rule per row and one rule per column boundary, and
    /// there is no outer frame at all. Each rule names the pane directly
    /// beneath it in every column, so the titles cost no extra lines:
    ///
    ///   --1 v Shell -------------------|--2 v Application --------------
    fn draw_grid(&self, canvas: &mut [Vec<char>], width: usize, height: usize) {
        let columns = if self.panes.len() <= 1 { 1 } else { 2 };
        let grid = Grid {
            width,
            columns,
            column_total: width.saturating_sub(columns - 1),
            rows: self.panes.len().div_ceil(columns),
        };
        if grid.rows == 0 || height <= grid.rows {
            return;
        }

        // One rule above each row and none below the last, so a name sits over
        // the pane it names and the footer closes the grid.
        let rules = grid.rows;
        if height <= rules {
            return;
        }
        let content_total = height - rules;

        let mut y = 0;
        for row in 0..grid.rows {
            let content_height =
                (row + 1) * content_total / grid.rows - row * content_total / grid.rows;
            self.draw_rule(canvas, y, &grid, row);
            y += 1;
            let mut x = 0;
            for column in 0..columns {
                let pane_width = (column + 1) * grid.column_total / columns
                    - column * grid.column_total / columns;
                if let Some(index) = row.checked_mul(columns).map(|base| base + column)
                    && index < self.panes.len()
                {
                    self.draw_pane_content(canvas, index, x, y, pane_width, content_height);
                }
                x += pane_width;
                if column + 1 < columns {
                    for line in y..(y + content_height).min(canvas.len()) {
                        if x < canvas[line].len() {
                            canvas[line][x] = '|';
                        }
                    }
                    x += 1;
                }
            }
            y += content_height;
        }
    }

    /// Draw one horizontal rule, naming the pane it sits over in each column.
    fn draw_rule(&self, canvas: &mut [Vec<char>], y: usize, grid: &Grid, row: usize) {
        if y >= canvas.len() {
            return;
        }
        for cell in canvas[y].iter_mut().take(grid.width) {
            *cell = '-';
        }
        let columns = grid.columns;
        let mut x = 0;
        for column in 0..columns {
            let pane_width = (column + 1) * grid.column_total / columns
                - column * grid.column_total / columns;
            // One name per column, for the pane directly beneath. Naming both
            // neighbours would repeat every middle pane's name on two rules
            // and leave each one half a column to fit in.
            let index = row * columns + column;
            if index < self.panes.len() {
                let lead = usize::from(self.label_for(index).chars().count() + 2 <= pane_width) * 2;
                self.write_label(canvas, y, x + lead, x + pane_width, index);
            }
            x += pane_width;
            if column + 1 < columns {
                if x < canvas[y].len() {
                    canvas[y][x] = '|';
                }
                x += 1;
            }
        }
    }

    fn label_for(&self, index: usize) -> String {
        let pane = &self.panes[index];
        // Two numbers matter and they are not the same: Ctrl-A takes the pane
        // number, while the debugger, mon and ps all take the endpoint. Naming
        // only the first invites killing endpoint 12 while watching pane 12,
        // which shows a different process. The pane number leads because it
        // survives truncation in a narrow column; the endpoint follows for
        // panes that have one.
        format!(
            "{} v {}{}{}{}{}",
            index + 1,
            pane.title,
            match pane.kind {
                PaneKind::Application => format!(" ep={}", u16::from(pane.channel) + 1),
                _ => String::new(),
            },
            if pane.ended { " (ended)" } else { "" },
            if pane.alert { " !" } else { "" },
            if index == self.focus { " *" } else { "" }
        )
    }

    /// Write a name onto a rule, clipped to this column. Returns the column
    /// after the text.
    fn write_label(
        &self,
        canvas: &mut [Vec<char>],
        y: usize,
        x: usize,
        end: usize,
        index: usize,
    ) -> usize {
        let label = self.label_for(index);
        let mut column = x;
        for character in label.chars() {
            if column >= end || column >= canvas[y].len() {
                break;
            }
            canvas[y][column] = character;
            column += 1;
        }
        column
    }

    /// Pane contents, with no border of its own.
    fn draw_pane_content(
        &self,
        canvas: &mut [Vec<char>],
        index: usize,
        x: usize,
        y: usize,
        width: usize,
        height: usize,
    ) {
        let lines = self.panes[index].visible_lines(height);
        let horizontal_offset = self.panes[index].horizontal_offset;
        for (row, line) in lines.iter().take(height).enumerate() {
            let target = y + row;
            if target >= canvas.len() {
                break;
            }
            for (column, character) in line
                .chars()
                .skip(horizontal_offset)
                .take(width)
                .enumerate()
            {
                let cell = x + column;
                if cell < canvas[target].len() {
                    canvas[target][cell] = character;
                }
            }
        }
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
        assert_eq!(desktop.command(b'd'), CommandOutcome::Detach);
    }

    #[test]
    fn closed_system_panes_can_be_restored() {
        let mut desktop = Desktop::new(2);
        desktop.command(b'3');
        assert_eq!(desktop.focused_kind(), PaneKind::Debugger);
        desktop.command(b'x');
        assert!(!desktop
            .layout()
            .iter()
            .any(|(kind, _, _)| *kind == PaneKind::Debugger));

        desktop.command(b'S');
        let layout = desktop.layout();
        assert_eq!(layout.len(), PaneKind::ALL.len());
        // Restored at its canonical position, so Ctrl-A 4 still reaches it.
        desktop.command(b'3');
        assert_eq!(desktop.focused_kind(), PaneKind::Debugger);
        // Restoring again is a no-op rather than a duplicate.
        desktop.command(b'S');
        assert_eq!(desktop.layout().len(), PaneKind::ALL.len());
    }

    #[test]
    fn a_pane_says_when_its_process_has_ended_and_can_be_reclaimed() {
        let mut desktop = Desktop::new(10);
        desktop.add_application(4, "clock");
        desktop.push_channel(4, b"00:01\n");

        // Endpoint five is running: the pane is live and says nothing extra.
        desktop.mark_live_endpoints(&[1, 5]);
        let screen = desktop.render(100, 24);
        assert!(screen.contains("clock ep=5"), "{screen}");
        assert!(!screen.contains("(ended)"), "{screen}");

        // It exits. The pane keeps what it printed and says so.
        desktop.mark_live_endpoints(&[1]);
        let screen = desktop.render(100, 24);
        assert!(screen.contains("clock ep=5 (ended)"), "{screen}");
        assert!(screen.contains("00:01"), "output must survive: {screen}");

        // A pane that never held a process is not a dead one.
        assert!(!desktop.render(100, 24).contains("Application ep=2 (ended)"));

        // Reclaiming the space closes it and leaves the rest alone.
        let before = desktop.pane_count();
        desktop.command(b'c');
        assert_eq!(desktop.pane_count(), before - 1);
        // The footer carries a wall clock of its own; look for the pane.
        let after = desktop.render(100, 24);
        assert!(!after.contains("v clock"), "{after}");
        assert!(desktop.render(100, 24).contains("1 v Shell"));
    }

    #[test]
    fn a_pane_can_be_cleared_and_stays_open() {
        let mut desktop = Desktop::new(10);
        desktop.push_channel(0, b"old output\n");
        assert!(desktop.render(80, 24).contains("old output"));
        desktop.command(b'l');
        let screen = desktop.render(80, 24);
        assert!(!screen.contains("old output"), "{screen}");
        assert!(screen.contains("1 v Shell"), "the pane must stay open: {screen}");

        // Reusing a channel starts the new program's pane empty.
        desktop.push_channel(0, b"newer output\n");
        desktop.clear_channel(0);
        assert!(!desktop.render(80, 24).contains("newer output"));
    }

    #[test]
    fn form_feed_clears_a_pane_for_redraw() {
        let mut desktop = Desktop::new(10);
        desktop.push_channel(0, b"first report\nsecond line\n");
        assert!(desktop.render(80, 24).contains("first report"));
        desktop.push_channel(0, b"\x0csecond report\n");
        let screen = desktop.render(80, 24);
        assert!(!screen.contains("first report"), "{screen}");
        assert!(screen.contains("second report"), "{screen}");
    }

    #[test]
    fn a_pane_bounds_a_line_that_never_ends() {
        // A clock printing forever is bounded by the scrollback limit, but a
        // program that emits no newline at all is only bounded by the line cap.
        let mut desktop = Desktop::new(1);
        for _ in 0..(MAX_LINE_BYTES * DEFAULT_SCROLLBACK * 2 / 1024) {
            desktop.push_channel(0, &[b'x'; 1024]);
        }
        let pane = &desktop.panes[0];
        assert!(pane.current.len() < MAX_LINE_BYTES, "{}", pane.current.len());
        assert!(pane.lines.len() <= DEFAULT_SCROLLBACK, "{}", pane.lines.len());
    }

    #[test]
    fn each_rule_names_the_panes_beneath_it_once_and_follows_focus() {
        // A rule names only what is directly under it, so every pane is named
        // exactly once. Naming both neighbours would repeat each middle pane
        // on two rules and leave every name half a column to fit in.
        let mut desktop = Desktop::new(4);
        desktop.push_channel(0, b"shell-body\n");
        desktop.push_channel(2, b"debugger-body\n");
        // Strip the cursor-home and clear-to-end controls so a rule is
        // recognisable by its first character wherever it sits.
        let plain = |desktop: &Desktop| {
            desktop.render(80, 24).replace("\x1b[H", "").replace("\x1b[K", "")
        };
        let screen = plain(&desktop);
        let rules: Vec<&str> = screen
            .lines()
            .filter(|line| line.starts_with('-'))
            .collect();

        // Two rows, so two rules: one over each row, none below the last.
        assert_eq!(rules.len(), 2, "{screen}");
        assert!(screen.lines().next().unwrap().starts_with('-'), "{screen}");
        assert!(!screen.lines().last().unwrap().starts_with('-'), "{screen}");

        let split = |rule: &str| {
            let column = rule.find('|').expect("column separator");
            let (left, right) = rule.split_at(column);
            (left.to_string(), right.to_string())
        };
        let (top_left, top_right) = split(rules[0]);
        let (low_left, _low_right) = split(rules[1]);
        assert!(top_left.contains("1 v Shell"), "{top_left}");
        assert!(top_right.contains("2 v Application"), "{top_right}");
        assert!(low_left.contains("3 v Debugger"), "{low_left}");

        // No name appears twice anywhere on the screen's rules.
        for name in ["Shell", "Application", "Debugger"] {
            let seen: usize = rules.iter().map(|rule| rule.matches(name).count()).sum();
            assert_eq!(seen, 1, "{name} named {seen} times");
        }

        // The marker sits on the focused pane's own name, and only there.
        assert!(top_left.contains("1 v Shell *"), "{top_left}");
        assert_eq!(
            rules.iter().map(|rule| rule.matches('*').count()).sum::<usize>(),
            1,
            "{screen}"
        );

        desktop.command(b'3');
        let screen = plain(&desktop);
        let rules: Vec<&str> = screen
            .lines()
            .filter(|line| line.starts_with('-'))
            .collect();
        assert!(rules[1].contains("3 v Debugger *"), "{}", rules[1]);
        assert!(!rules[0].contains("1 v Shell *"), "{}", rules[0]);
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
        assert!(small.contains("Debugger"));
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
        assert_eq!(desktop.pane_count(), 4);
        desktop.command(b'1');
        desktop.push_channel(7, b"count 1\ncount 2\n");
        assert!(desktop.render(80, 24).contains("Counter ep=8 !"));
        desktop.command(b'4');
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
        assert_eq!(desktop.pane_count(), 4);
        desktop.release_channel(7);
        assert_eq!(desktop.pane_count(), 3);
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
