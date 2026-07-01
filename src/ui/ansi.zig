//! Double-buffered diff-based ANSI terminal renderer.
//!
//! Each frame: fill the "write" buffer → diff against "read" buffer →
//! emit only changed cells as ANSI sequences → flush via single write(2) call.
//!
//! Zig 0.16: std.io is gone. Uses raw linux.write for all output.

const std = @import("std");
const linux = std.os.linux;

pub const Color = enum(u8) {
    default = 39,
    black   = 30,
    red     = 31,
    green   = 32,
    yellow  = 33,
    blue    = 34,
    magenta = 35,
    cyan    = 36,
    white   = 37,
    bright_black   = 90,
    bright_red     = 91,
    bright_green   = 92,
    bright_yellow  = 93,
    bright_blue    = 94,
    bright_magenta = 95,
    bright_cyan    = 96,
    bright_white   = 97,
};

pub const Attr = packed struct(u8) {
    bold:      bool = false,
    dim:       bool = false,
    underline: bool = false,
    _pad: u5 = 0,
};

pub const Cell = packed struct {
    ch:   u8 = ' ',
    fg:   Color = .default,
    bg:   Color = .default,
    attr: Attr = .{},
};

pub const Screen = struct {
    cols: u16,
    rows: u16,
    cur:  []Cell,
    prev: []Cell,
    alloc: std.mem.Allocator,
    out_buf: []u8,   // pre-allocated output scratch (single write per frame)
    out_len: usize,

    const OUT_BUF_SIZE = 512 * 1024; // 512KB — more than enough for any terminal

    pub fn init(alloc: std.mem.Allocator) !Screen {
        const sz = detectSize();
        const n = @as(usize, sz.cols) * sz.rows;
        const cur  = try alloc.alloc(Cell, n);
        const prev = try alloc.alloc(Cell, n);
        @memset(cur,  Cell{});
        @memset(prev, Cell{ .ch = 0 }); // force full redraw on first frame
        const out_buf = try alloc.alloc(u8, OUT_BUF_SIZE);
        return .{
            .cols = sz.cols,
            .rows = sz.rows,
            .cur  = cur,
            .prev = prev,
            .alloc = alloc,
            .out_buf = out_buf,
            .out_len = 0,
        };
    }

    pub fn deinit(self: *Screen) void {
        self.alloc.free(self.cur);
        self.alloc.free(self.prev);
        self.alloc.free(self.out_buf);
    }

    pub fn resize(self: *Screen) void {
        const sz = detectSize();
        if (sz.cols == self.cols and sz.rows == self.rows) return;
        const n = @as(usize, sz.cols) * sz.rows;
        self.alloc.free(self.cur);
        self.alloc.free(self.prev);
        self.cur  = self.alloc.alloc(Cell, n) catch return;
        self.prev = self.alloc.alloc(Cell, n) catch return;
        @memset(self.cur,  Cell{});
        @memset(self.prev, Cell{ .ch = 0 });
        self.cols = sz.cols;
        self.rows = sz.rows;
    }

    pub fn clear(self: *Screen) void {
        @memset(self.cur, Cell{});
    }

    pub fn put(self: *Screen, row: u16, col: u16, cell: Cell) void {
        if (row >= self.rows or col >= self.cols) return;
        self.cur[@as(usize, row) * self.cols + col] = cell;
    }

    pub fn putStr(self: *Screen, row: u16, col: u16, s: []const u8, fg: Color, bg: Color, attr: Attr) void {
        for (s, 0..) |ch, i| {
            const c: u16 = col + @as(u16, @intCast(i));
            if (c >= self.cols) break;
            self.put(row, c, .{ .ch = ch, .fg = fg, .bg = bg, .attr = attr });
        }
    }

    pub fn putBar(self: *Screen, row: u16, col: u16, width: u16, pct: f32, fg: Color, bg: Color) void {
        const filled: u16 = @intFromFloat(@min(@as(f32, @floatFromInt(width)) * pct / 100.0, @as(f32, @floatFromInt(width))));
        for (0..width) |i| {
            const c = col + @as(u16, @intCast(i));
            const ch: u8 = if (i < filled) '|' else ' ';
            const actual_fg: Color = if (i < filled) fg else .default;
            self.put(row, c, .{ .ch = ch, .fg = actual_fg, .bg = bg, .attr = .{} });
        }
    }

    pub fn putSparkline(self: *Screen, row: u16, col: u16, width: u16, samples: []const f32) void {
        const n_blocks: usize = 9;
        const take = @min(samples.len, @as(usize, width));
        const start = samples.len - take;

        for (0..@as(usize, width)) |i| {
            const c = col + @as(u16, @intCast(i));
            if (i >= take) {
                self.put(row, c, .{ .ch = ' ', .fg = .default, .bg = .default, .attr = .{} });
                continue;
            }
            const pct = @max(0.0, @min(100.0, samples[start + i]));
            const idx: usize = @intFromFloat(pct / 100.0 * @as(f32, @floatFromInt(n_blocks - 1)));
            const ascii: u8 = switch (idx) {
                0 => ' ', 1 => '.', 2 => ',', 3 => '-',
                4 => '+', 5 => '~', 6 => '=', 7 => '#', else => '@',
            };
            const fg: Color = if (pct > 80.0) .red
                else if (pct > 50.0) .yellow
                else .green;
            self.put(row, c, .{ .ch = ascii, .fg = fg, .bg = .default, .attr = .{} });
        }
    }

    // ── Output buffer helpers ─────────────────────────────────────────────────

    fn emit(self: *Screen, bytes: []const u8) void {
        const space = self.out_buf.len - self.out_len;
        const n = @min(bytes.len, space);
        @memcpy(self.out_buf[self.out_len..][0..n], bytes[0..n]);
        self.out_len += n;
    }

    fn emitFmt(self: *Screen, comptime fmt: []const u8, args: anytype) void {
        const remaining = self.out_buf[self.out_len..];
        const s = std.fmt.bufPrint(remaining, fmt, args) catch return;
        self.out_len += s.len;
    }

    // ── Flush ─────────────────────────────────────────────────────────────────

    pub fn flush(self: *Screen) !void {
        self.out_len = 0;

        self.emit("\x1b[?25l"); // hide cursor

        var last_row: u16 = 9999;
        var last_col: u16 = 9999;
        var last_fg:  Color = .default;
        var last_bg:  Color = .default;
        var last_attr: Attr = .{};

        for (0..self.rows) |r| {
            for (0..self.cols) |c| {
                const idx = r * self.cols + c;
                const cell = self.cur[idx];
                const old  = self.prev[idx];
                if (std.meta.eql(cell, old)) continue;

                const row: u16 = @intCast(r);
                const col: u16 = @intCast(c);
                if (row != last_row or col != last_col + 1) {
                    self.emitFmt("\x1b[{d};{d}H", .{ row + 1, col + 1 });
                }

                if (cell.fg != last_fg or cell.bg != last_bg or !std.meta.eql(cell.attr, last_attr)) {
                    self.emit("\x1b[");
                    var need_semi = false;
                    if (!std.meta.eql(cell.attr, last_attr)) {
                        self.emit("0");
                        need_semi = true;
                    }
                    if (cell.fg != last_fg or !std.meta.eql(cell.attr, last_attr)) {
                        if (need_semi) self.emit(";");
                        self.emitFmt("{d}", .{@intFromEnum(cell.fg)});
                        if (cell.attr.bold) self.emit(";1");
                        if (cell.attr.dim) self.emit(";2");
                        if (cell.attr.underline) self.emit(";4");
                        need_semi = true;
                    }
                    if (cell.bg != last_bg) {
                        if (need_semi) self.emit(";");
                        self.emitFmt("{d}", .{@intFromEnum(cell.bg) + 10});
                    }
                    self.emit("m");
                    last_fg = cell.fg;
                    last_bg = cell.bg;
                    last_attr = cell.attr;
                }

                self.out_buf[self.out_len] = cell.ch;
                self.out_len += 1;
                last_row = row;
                last_col = col;
            }
        }

        self.emit("\x1b[0m\x1b[?25h"); // reset + show cursor

        // Single write syscall
        _ = linux.write(1, self.out_buf.ptr, self.out_len);

        @memcpy(self.prev, self.cur);
    }

    pub fn enterAlt(self: *Screen) void {
        _ = self;
        _ = linux.write(1, "\x1b[?1049h\x1b[2J\x1b[?25l", 19);
    }

    pub fn exitAlt(self: *Screen) void {
        _ = self;
        _ = linux.write(1, "\x1b[?1049l\x1b[?25h", 15);
    }
};

const TermSize = struct { cols: u16, rows: u16 };

fn detectSize() TermSize {
    const TIOCGWINSZ: u32 = 0x5413;
    const WinSize = extern struct {
        ws_row: u16,
        ws_col: u16,
        ws_xpixel: u16,
        ws_ypixel: u16,
    };
    var ws: WinSize = .{ .ws_row = 24, .ws_col = 80, .ws_xpixel = 0, .ws_ypixel = 0 };
    _ = linux.syscall3(.ioctl, 1, TIOCGWINSZ, @intFromPtr(&ws));
    return .{
        .cols = if (ws.ws_col == 0) 80 else ws.ws_col,
        .rows = if (ws.ws_row == 0) 24 else ws.ws_row,
    };
}

// ── Formatting helpers ────────────────────────────────────────────────────────

pub fn fmtKib(buf: []u8, kb: u64) []const u8 {
    if (kb >= 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d:.1}G", .{@as(f64, @floatFromInt(kb)) / (1024 * 1024)}) catch "?";
    } else if (kb >= 1024) {
        return std.fmt.bufPrint(buf, "{d:.1}M", .{@as(f64, @floatFromInt(kb)) / 1024}) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d}K", .{kb}) catch "?";
    }
}

pub fn fmtUptime(buf: []u8, s: u64) []const u8 {
    const h = s / 3600;
    const m = (s % 3600) / 60;
    const sec = s % 60;
    if (h > 0) {
        return std.fmt.bufPrint(buf, "{d}h{d:0>2}m{d:0>2}s", .{ h, m, sec }) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d}m{d:0>2}s", .{ m, sec }) catch "?";
    }
}
