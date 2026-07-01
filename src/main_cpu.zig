//! ztop — Zig-native system monitor.
//!
//! Architecture: arena-per-tick frame loop
//!   1. Collect CPU snapshot (linux.zig)
//!   2. Push into HistoryBuf (types.zig)
//!   3. Collect process list (linux.zig)
//!   4. Render to screen (ansi.zig)
//!   5. Sleep 1s, repeat
//!
//! The temporal rewind (`asof`) is the primary differentiator:
//!   pressing 'r' + arrow rewinds history — no other system monitor does this.

const std = @import("std");
const core = @import("core");
const cpu  = @import("cpu");
const util = @import("util");
const ansi = @import("ui/ansi.zig");

// SIGWINCH handler for terminal resize
var resize_pending = std.atomic.Value(bool).init(false);

fn onSigwinch(_: std.os.linux.SIG) callconv(.c) void {
    resize_pending.store(true, .release);
}

fn onSigint(_: std.os.linux.SIG) callconv(.c) void {
    should_exit.store(true, .release);
}

var should_exit = std.atomic.Value(bool).init(false);

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const perm_alloc = gpa.allocator();

    // Install signal handlers
    const linux = std.os.linux;
    var sa_winch: linux.Sigaction = .{
        .handler = .{ .handler = onSigwinch },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(linux.SIG.WINCH, &sa_winch, null);

    var sa_int: linux.Sigaction = .{
        .handler = .{ .handler = onSigint },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(linux.SIG.INT, &sa_int, null);

    // Init collector (reads first /proc/stat baseline)
    var collector = try cpu.Collector.init(perm_alloc);

    // Init screen
    var screen = try ansi.Screen.init(perm_alloc);
    defer screen.deinit();
    screen.enterAlt();
    defer screen.exitAlt();

    // Init history ring buffer
    var history = core.HistoryBuf.init();

    // Rewind mode state
    var rewind_offset_s: i64 = 0; // 0 = live; positive = seconds into past

    // Set stdin non-blocking for keyboard input
    const stdin_fd = std.posix.STDIN_FILENO;
    const old_termios: std.posix.termios = try std.posix.tcgetattr(stdin_fd);
    var raw = old_termios;
    raw.lflag.ECHO   = false;
    raw.lflag.ICANON = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)]  = 0;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(stdin_fd, .NOW, raw);
    defer std.posix.tcsetattr(stdin_fd, .NOW, old_termios) catch {};

    // Main loop
    var arena = std.heap.ArenaAllocator.init(perm_alloc);
    defer arena.deinit();

    while (!should_exit.load(.acquire)) {
        _ = arena.reset(.retain_capacity);
        const frame_alloc = arena.allocator();

        // Handle resize
        if (resize_pending.cmpxchgStrong(true, false, .acq_rel, .acquire) == null) {
            screen.resize();
        }

        // Collect
        const snap = try collector.collect(frame_alloc);
        history.push(snap);
        const procs = try collector.collectProcesses(frame_alloc, &snap);

        // Handle keyboard input (non-blocking)
        var key_buf: [8]u8 = undefined;
        const nread = std.posix.read(stdin_fd, &key_buf) catch 0;
        if (nread > 0) {
            switch (key_buf[0]) {
                'q', 3 => should_exit.store(true, .release), // q or Ctrl-C
                'r' => { // rewind mode
                    if (nread >= 3 and key_buf[1] == 0x1b and key_buf[2] == '[') {
                        switch (key_buf[3]) {
                            'D' => rewind_offset_s += 5,  // left arrow = 5s back
                            'C' => rewind_offset_s = @max(0, rewind_offset_s - 5), // right = forward
                            else => {},
                        }
                    }
                },
                0x1b => { // ESC = exit rewind
                    rewind_offset_s = 0;
                },
                else => {},
            }
        }

        // Render
        screen.clear();
        renderFrame(&screen, &snap, &history, procs, rewind_offset_s, frame_alloc);
        try screen.flush();

        util.sleep(1_000_000_000); // 1Hz
    }
}

fn renderFrame(
    s: *ansi.Screen,
    snap: *const core.CpuSnapshot,
    history: *const core.HistoryBuf,
    procs: []const core.ProcessInfo,
    rewind_offset_s: i64,
    alloc: std.mem.Allocator,
) void {
    _ = alloc;
    const cols = s.cols;
    const rows = s.rows;

    var tmp: [128]u8 = undefined;

    // ── Row 0: header bar ────────────────────────────────────────────────────
    const uptime_str = ansi.fmtUptime(&tmp, snap.uptime_s);
    var hdr: [256]u8 = undefined;
    const hdr_s = std.fmt.bufPrint(&hdr,
        " ztop v0.0.1  up {s}  load: {d:.2} {d:.2} {d:.2}",
        .{ uptime_str, snap.load_1, snap.load_5, snap.load_15 }) catch " ztop";
    s.putStr(0, 0, hdr_s, .black, .cyan, .{ .bold = true });
    // Fill rest of header
    for (hdr_s.len..@as(usize, cols)) |c| {
        s.put(0, @intCast(c), .{ .ch = ' ', .fg = .black, .bg = .cyan, .attr = .{} });
    }

    // ── Rows 1-2: rewind indicator ───────────────────────────────────────────
    if (rewind_offset_s > 0) {
        const rw_s = std.fmt.bufPrint(&tmp,
            " [REWIND -{d}s] (arrows to navigate, ESC to exit)", .{rewind_offset_s}) catch "";
        s.putStr(1, 0, rw_s, .yellow, .default, .{ .bold = true });
    }

    // ── Rows 2+: CPU bars (one per core + aggregate) ─────────────────────────
    const bar_start_row: u16 = 2;
    const bar_width: u16 = if (cols > 40) cols / 2 - 15 else 10;

    // Aggregate CPU
    {
        const label = std.fmt.bufPrint(&tmp, "CPU  ", .{}) catch "CPU  ";
        s.putStr(bar_start_row, 0, label, .bright_white, .default, .{});
        const pct = snap.total_pct;
        const fg: ansi.Color = if (pct > 80.0) .red else if (pct > 50.0) .yellow else .green;
        s.putStr(bar_start_row, 5, "[", .default, .default, .{});
        s.putBar(bar_start_row, 6, bar_width, pct, fg, .default);
        s.putStr(bar_start_row, 6 + bar_width, "]", .default, .default, .{});
        const pct_s = std.fmt.bufPrint(&tmp, " {d:5.1}%", .{pct}) catch "";
        s.putStr(bar_start_row, 7 + bar_width, pct_s, fg, .default, .{});
    }

    // Per-core bars (up to available rows, 2 rows after aggregate)
    const max_core_rows = @min(snap.core_pct.len, @as(usize, rows) - 10);
    for (snap.core_pct[0..max_core_rows], 0..) |pct, i| {
        const row: u16 = bar_start_row + 1 + @as(u16, @intCast(i));
        const label = std.fmt.bufPrint(&tmp, "CPU{d:<2}", .{i}) catch "CPU? ";
        s.putStr(row, 0, label, .default, .default, .{});
        const fg: ansi.Color = if (pct > 80.0) .red else if (pct > 50.0) .yellow else .green;
        s.putStr(row, 5, "[", .default, .default, .{});
        s.putBar(row, 6, bar_width, pct, fg, .default);
        s.putStr(row, 6 + bar_width, "]", .default, .default, .{});
        const pct_s = std.fmt.bufPrint(&tmp, " {d:5.1}%", .{pct}) catch "";
        s.putStr(row, 7 + bar_width, pct_s, fg, .default, .{});
    }

    // ── Memory row ───────────────────────────────────────────────────────────
    const mem_row: u16 = bar_start_row + 1 + @as(u16, @intCast(max_core_rows));
    {
        s.putStr(mem_row, 0, "Mem  ", .bright_white, .default, .{});
        const used_pct = if (snap.mem_total_kb == 0) 0.0
            else @as(f32, @floatFromInt(snap.mem_used_kb())) * 100.0 /
                 @as(f32, @floatFromInt(snap.mem_total_kb));
        s.putStr(mem_row, 5, "[", .default, .default, .{});
        const fg: ansi.Color = if (used_pct > 90.0) .red else if (used_pct > 70.0) .yellow else .cyan;
        s.putBar(mem_row, 6, bar_width, used_pct, fg, .default);
        s.putStr(mem_row, 6 + bar_width, "]", .default, .default, .{});
        var mbuf1: [16]u8 = undefined;
        var mbuf2: [16]u8 = undefined;
        const used_s = ansi.fmtKib(&mbuf1, snap.mem_used_kb());
        const total_s = ansi.fmtKib(&mbuf2, snap.mem_total_kb);
        const mem_s = std.fmt.bufPrint(&tmp, " {s}/{s}", .{ used_s, total_s }) catch "";
        s.putStr(mem_row, 7 + bar_width, mem_s, fg, .default, .{});
    }

    // ── Swap row ─────────────────────────────────────────────────────────────
    const swap_row = mem_row + 1;
    if (snap.swap_total_kb > 0) {
        s.putStr(swap_row, 0, "Swap ", .bright_white, .default, .{});
        const used_pct = if (snap.swap_total_kb == 0) 0.0
            else @as(f32, @floatFromInt(snap.swap_used_kb())) * 100.0 /
                 @as(f32, @floatFromInt(snap.swap_total_kb));
        s.putStr(swap_row, 5, "[", .default, .default, .{});
        s.putBar(swap_row, 6, bar_width, used_pct, .magenta, .default);
        s.putStr(swap_row, 6 + bar_width, "]", .default, .default, .{});
        var sbuf1: [16]u8 = undefined;
        var sbuf2: [16]u8 = undefined;
        const used_s = ansi.fmtKib(&sbuf1, snap.swap_used_kb());
        const total_s = ansi.fmtKib(&sbuf2, snap.swap_total_kb);
        const s_str = std.fmt.bufPrint(&tmp, " {s}/{s}", .{ used_s, total_s }) catch "";
        s.putStr(swap_row, 7 + bar_width, s_str, .magenta, .default, .{});
    }

    // ── History sparkline (right side of screen) ──────────────────────────────
    const spark_col: u16 = cols / 2 + 2;
    const spark_width: u16 = if (cols > spark_col + 10) cols - spark_col - 2 else 10;
    if (spark_col + spark_width < cols) {
        s.putStr(bar_start_row, spark_col - 8, "History:", .bright_white, .default, .{});
        var spark_buf: [1800]f32 = undefined;
        const n_samp = history.lastN(@as(usize, spark_width), spark_buf[0..]);
        s.putSparkline(bar_start_row + 1, spark_col, spark_width, spark_buf[0..n_samp]);

        // Rewind point indicator
        if (rewind_offset_s > 0) {
            const target_ns = util.nanoTimestamp() - rewind_offset_s * 1_000_000_000;
            if (history.asof(target_ns)) |pct| {
                var rw_buf: [32]u8 = undefined;
                const rw_s = std.fmt.bufPrint(&rw_buf, "@ -{d}s: {d:.1}%", .{ rewind_offset_s, pct }) catch "";
                s.putStr(bar_start_row + 2, spark_col, rw_s, .yellow, .default, .{ .bold = true });
            }
        }
    }

    // ── Process table ─────────────────────────────────────────────────────────
    const proc_header_row: u16 = swap_row + 2;
    const ipc_available = procs.len > 0 and !std.math.isNan(procs[0].ipc);

    // Column header
    s.putStr(proc_header_row, 0, "  PID", .black, .white, .{ .bold = true });
    s.putStr(proc_header_row, 6, " S", .black, .white, .{ .bold = true });
    s.putStr(proc_header_row, 9, "   CPU%", .black, .white, .{ .bold = true });
    s.putStr(proc_header_row, 17, "    RES", .black, .white, .{ .bold = true });
    if (ipc_available) {
        s.putStr(proc_header_row, 25, "  IPC", .black, .white, .{ .bold = true });
    }
    const name_col: u16 = if (ipc_available) 31 else 25;
    s.putStr(proc_header_row, name_col, " NAME", .black, .white, .{ .bold = true });
    for (@as(usize, name_col) + 5..@as(usize, cols)) |c| {
        s.put(proc_header_row, @intCast(c), .{ .ch = ' ', .fg = .black, .bg = .white, .attr = .{} });
    }

    // Process rows
    const max_proc_rows = if (rows > proc_header_row + 2)
        @as(usize, rows - proc_header_row - 2)
    else
        0;
    const n_procs = @min(procs.len, max_proc_rows);

    for (procs[0..n_procs], 0..) |proc, i| {
        const row: u16 = proc_header_row + 1 + @as(u16, @intCast(i));
        const is_hot = proc.cpu_pct > 10.0;
        const row_fg: ansi.Color = if (is_hot) .yellow else .default;

        // PID
        const pid_s = std.fmt.bufPrint(&tmp, "{d:>5}", .{proc.pid}) catch "?????";
        s.putStr(row, 0, pid_s, row_fg, .default, .{});

        // State
        s.put(row, 6, .{ .ch = ' ', .fg = .default, .bg = .default, .attr = .{} });
        const state_fg: ansi.Color = switch (proc.state) {
            'R' => .green,
            'D' => .red,
            'Z' => .magenta,
            else => .default,
        };
        s.put(row, 7, .{ .ch = proc.state, .fg = state_fg, .bg = .default, .attr = .{} });

        // CPU%
        const cpu_s = std.fmt.bufPrint(&tmp, " {d:6.1}%", .{proc.cpu_pct}) catch "       ";
        const cpu_fg: ansi.Color = if (proc.cpu_pct > 50.0) .red
            else if (proc.cpu_pct > 10.0) .yellow else .default;
        s.putStr(row, 9, cpu_s, cpu_fg, .default, .{});

        // RES
        var res_buf: [16]u8 = undefined;
        const res_s = ansi.fmtKib(&res_buf, proc.rss_kb);
        const res_padded = std.fmt.bufPrint(&tmp, " {s:>6}", .{res_s}) catch "       ";
        s.putStr(row, 17, res_padded, .default, .default, .{});

        // IPC (the killer column no htop/btop/bottom shows)
        if (ipc_available) {
            var ipc_buf: [16]u8 = undefined;
            const ipc_s = if (std.math.isNan(proc.ipc)) "  N/A"
                else std.fmt.bufPrint(&ipc_buf, " {d:.2}", .{proc.ipc}) catch "  N/A";
            const ipc_fg: ansi.Color = if (std.math.isNan(proc.ipc)) .bright_black
                else if (proc.ipc > 3.0) .bright_green
                else if (proc.ipc > 1.5) .green else .yellow;
            s.putStr(row, 25, ipc_s, ipc_fg, .default, .{});
        }

        // Name
        const name = proc.nameSlice();
        const name_display = std.fmt.bufPrint(&tmp, " {s}", .{name}) catch "";
        s.putStr(row, name_col, name_display, row_fg, .default, .{});
    }

    // ── Status bar at bottom ──────────────────────────────────────────────────
    if (rows > 1) {
        const tasks_s = std.fmt.bufPrint(&tmp,
            " Tasks: {d}  |  q:quit  r+arrows:rewind  ESC:live",
            .{procs.len}) catch "";
        s.putStr(rows - 1, 0, tasks_s, .black, .bright_white, .{});
        for (tasks_s.len..@as(usize, cols)) |c| {
            s.put(rows - 1, @intCast(c), .{ .ch = ' ', .fg = .black, .bg = .bright_white, .attr = .{} });
        }
    }
}
