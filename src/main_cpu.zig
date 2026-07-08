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
const core    = @import("core");
const cpu     = @import("cpu");
const net     = @import("net");
const disk    = @import("disk");
const thermal = @import("thermal");
const log     = @import("log");
const api     = @import("api");
const tcp     = @import("tcp");
const util    = @import("util");
const ansi    = @import("ui/ansi.zig");

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
    var net_col   = try net.NetCollector.init(perm_alloc);
    defer net_col.deinit();
    var disk_col  = try disk.DiskCollector.init(perm_alloc);
    defer disk_col.deinit();
    var power_col = thermal.PowerCollector.init(util.nanoTimestamp());

    // REST API
    var api_snap = api.ApiSnapshot{};
    var api_srv  = api.ApiServer.init(&api_snap);
    const api_thread = api_srv.start() catch null;
    _ = api_thread;
    defer api_srv.stop();

    // Historical logger
    var logger = log.LogWriter{};
    logger.init();
    defer logger.deinit();
    var log_tick: u32 = 0; // write every 10 ticks

    // Init screen
    var screen = try ansi.Screen.init(perm_alloc);
    defer screen.deinit();
    screen.enterAlt();
    defer screen.exitAlt();

    // Init history ring buffer
    var history = core.HistoryBuf.init();

    // Rewind mode state
    var rewind_offset_s: i64 = 0; // 0 = live; positive = seconds into past
    var last_ts_ns: i64 = util.nanoTimestamp();

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
        const now_ns = util.nanoTimestamp();
        const dt_s = @max(0.001, @as(f32, @floatFromInt(now_ns - last_ts_ns)) / 1e9);
        last_ts_ns = now_ns;

        const snap = try collector.collect(frame_alloc);
        history.push(snap);
        const procs = try collector.collectProcesses(frame_alloc, &snap);
        const net_ifaces = net_col.collect(frame_alloc, dt_s) catch &.{};
        const disk_stats = disk_col.collect(frame_alloc, dt_s) catch &.{};
        // TCP connections: build inode→PID map, collect, annotate processes.
        var inode_pid = tcp.buildInodePidMap(frame_alloc);
        defer inode_pid.deinit();
        const tcp_conns = tcp.collectTcp(frame_alloc, &inode_pid) catch &.{};
        // Collect per-process disk rates, container labels, TCP conn counts.
        for (procs) |*p| {
            const rates = disk_col.pidIoRates(frame_alloc, p.pid, dt_s);
            p.disk_read_kb_s  = rates.r;
            p.disk_write_kb_s = rates.w;
            p.tcp_conn_count  = @intCast(@min(tcp.countPerPid(tcp_conns, p.pid), 65535));
            collectContainerLabel(frame_alloc, p);
        }
        const sensors     = thermal.collectThermal(frame_alloc) catch &.{};
        const cpu_freqs   = thermal.collectCpuFreqs(frame_alloc) catch &.{};
        const power_info  = power_col.sample(now_ns);

        // Publish to REST API.
        api_snap.updateCpu(&snap);
        {
            var cbuf: [8192]u8 = undefined;
            const cn = encodeTcpConns(tcp_conns, &cbuf);
            api_snap.updateConns(cbuf[0..cn]);
        }
        {
            var pbuf: [65536]u8 = undefined;
            const pn = api.encodeProcs(procs, &pbuf);
            api_snap.updateProcs(pbuf[0..pn]);
        }
        {
            var nbuf: [4096]u8 = undefined;
            const nn = api.encodeNet(net_ifaces, &nbuf);
            api_snap.updateNet(nbuf[0..nn]);
        }
        {
            var dbuf: [4096]u8 = undefined;
            const dn = api.encodeDisk(disk_stats, &dbuf);
            api_snap.updateDisk(dbuf[0..dn]);
        }
        {
            var tbuf: [4096]u8 = undefined;
            const tn = api.encodeThermal(sensors, cpu_freqs, &tbuf);
            api_snap.updateThermal(tbuf[0..tn]);
        }

        // Log every 10 ticks (~10s at 1Hz).
        log_tick += 1;
        if (log_tick >= 10) {
            log_tick = 0;
            logger.write(&snap, net_ifaces, disk_stats);
        }

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
        renderFrame(&screen, &snap, &history, procs, net_ifaces, disk_stats, sensors, cpu_freqs, power_info, rewind_offset_s, frame_alloc);
        try screen.flush();

        util.sleep(1_000_000_000); // 1Hz
    }
}

// Read container ID from /proc/PID/cgroup (first 12 chars of docker hex ID).
fn collectContainerLabel(alloc: std.mem.Allocator, p: *core.ProcessInfo) void {
    var path_buf: [64]u8 = undefined;
    const path_s = std.fmt.bufPrint(&path_buf, "/proc/{d}/cgroup", .{p.pid}) catch return;
    if (path_s.len + 1 >= path_buf.len) return;
    path_buf[path_s.len] = 0;
    const fd = std.posix.openatZ(std.posix.AT.FDCWD, path_buf[0..path_s.len :0],
        .{ .ACCMODE = .RDONLY }, 0) catch return;
    defer _ = std.os.linux.close(@intCast(fd));

    var data: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < data.len) {
        const n = std.posix.read(fd, data[total..]) catch break;
        if (n == 0) break;
        total += n;
    }

    // Look for docker/containerd hex IDs: "0::/docker/<64-hex-chars>" or similar.
    var lines = std.mem.splitScalar(u8, data[0..total], '\n');
    while (lines.next()) |line| {
        const marker = std.mem.indexOf(u8, line, "docker/") orelse
                       std.mem.indexOf(u8, line, "containerd/") orelse continue;
        const hex_start = marker + @as(usize, if (std.mem.indexOf(u8, line[marker..], "docker/") != null) 7 else 11);
        if (hex_start >= line.len) continue;
        const hex = line[hex_start..];
        // Verify it starts with hex chars.
        var valid_len: usize = 0;
        for (hex) |c| {
            if ((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')) {
                valid_len += 1;
                if (valid_len >= 12) break;
            } else break;
        }
        if (valid_len >= 12) {
            const copy_len: u8 = 12;
            @memcpy(p.container_id[0..copy_len], hex[0..copy_len]);
            p.container_id_len = copy_len;
        }
        break;
    }
    _ = alloc;
}

// Encode TCP connection slice into JSON for REST API.
fn encodeTcpConns(conns: []const tcp.TcpConn, buf: []u8) usize {
    var len: usize = 0;
    const write = struct {
        fn w(b: []u8, l: *usize, s: []const u8) void {
            const n = @min(s.len, b.len -| l.*);
            @memcpy(b[l.* .. l.* + n], s[0..n]);
            l.* += n;
        }
    }.w;
    write(buf, &len, "[");
    var first = true;
    for (conns) |c| {
        if (c.state != .established) continue; // only established for REST default
        if (!first) write(buf, &len, ",");
        first = false;
        var tmp: [256]u8 = undefined;
        const entry = std.fmt.bufPrint(&tmp,
            "{{\"pid\":{d},\"lport\":{d},\"rport\":{d},\"state\":\"{s}\"}}",
            .{ c.pid, c.local_port, c.remote_port, c.state.name() }) catch continue;
        write(buf, &len, entry);
    }
    write(buf, &len, "]");
    return len;
}

fn renderFrame(
    s: *ansi.Screen,
    snap: *const core.CpuSnapshot,
    history: *const core.HistoryBuf,
    procs: []const core.ProcessInfo,
    net_ifaces: []const core.NetIface,
    disk_stats: []const core.DiskStat,
    sensors: []const core.ThermalSensor,
    cpu_freqs: []const core.CpuFreq,
    power_info: core.PowerInfo,
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

    // ── Network I/O panel (right column, below sparkline) ────────────────────
    const net_col_start: u16 = cols / 2 + 2;
    var net_row: u16 = bar_start_row + 4;
    if (net_ifaces.len > 0 and net_col_start + 20 < cols) {
        s.putStr(net_row, net_col_start, "Net:", .bright_white, .default, .{ .bold = true });
        net_row += 1;
        for (net_ifaces[0..@min(net_ifaces.len, 4)]) |iface| {
            var nb1: [12]u8 = undefined;
            var nb2: [12]u8 = undefined;
            const rx_s = ansi.fmtKib(&nb1, @intFromFloat(iface.rx_rate_kb_s * 1024));
            const tx_s = ansi.fmtKib(&nb2, @intFromFloat(iface.tx_rate_kb_s * 1024));
            const net_s = std.fmt.bufPrint(&tmp, " {s:<8} ↓{s:>6}/s ↑{s:>6}/s",
                .{ iface.name[0..iface.name_len], rx_s, tx_s }) catch "";
            const rx_hot = iface.rx_rate_kb_s > 1024 * 10;
            s.putStr(net_row, net_col_start, net_s,
                if (rx_hot) .yellow else .default, .default, .{});
            net_row += 1;
            if (net_row >= rows - 1) break;
        }
    }

    // ── Disk I/O panel ────────────────────────────────────────────────────────
    if (disk_stats.len > 0 and net_col_start + 20 < cols and net_row < rows - 3) {
        s.putStr(net_row, net_col_start, "Disk:", .bright_white, .default, .{ .bold = true });
        net_row += 1;
        for (disk_stats[0..@min(disk_stats.len, 3)]) |d| {
            var db1: [12]u8 = undefined;
            var db2: [12]u8 = undefined;
            const r_s = ansi.fmtKib(&db1, @intFromFloat(d.read_rate_kb_s * 1024));
            const w_s = ansi.fmtKib(&db2, @intFromFloat(d.write_rate_kb_s * 1024));
            const ds = std.fmt.bufPrint(&tmp, " {s:<7} R:{s:>6}/s W:{s:>6}/s",
                .{ d.name[0..d.name_len], r_s, w_s }) catch "";
            s.putStr(net_row, net_col_start, ds, .default, .default, .{});
            net_row += 1;
            if (net_row >= rows - 1) break;
        }
    }

    // ── Thermal panel ─────────────────────────────────────────────────────────
    if (sensors.len > 0 and net_col_start + 20 < cols and net_row < rows - 3) {
        s.putStr(net_row, net_col_start, "Temp:", .bright_white, .default, .{ .bold = true });
        net_row += 1;
        for (sensors[0..@min(sensors.len, 6)]) |sensor| {
            const tc = @as(f32, @floatFromInt(sensor.temp_mc)) / 1000.0;
            const fg: ansi.Color = if (tc > 85) .red else if (tc > 70) .yellow else .green;
            const label = if (sensor.label_len > 0) sensor.label[0..sensor.label_len] else sensor.chip[0..sensor.chip_len];
            const ts = std.fmt.bufPrint(&tmp, " {s:<14} {d:.0}°C", .{ label, tc }) catch "";
            s.putStr(net_row, net_col_start, ts, fg, .default, .{});
            net_row += 1;
            if (net_row >= rows - 1) break;
        }
    }

    // ── CPU freq + power (compact, same right column) ─────────────────────────
    if (cpu_freqs.len > 0 and net_col_start + 20 < cols and net_row < rows - 3) {
        var freq_line: [128]u8 = undefined;
        var fpos: usize = 0;
        const max_show = @min(cpu_freqs.len, 8);
        for (cpu_freqs[0..max_show]) |f| {
            const piece = std.fmt.bufPrint(freq_line[fpos..], "{d:.1}G ", .{@as(f32, @floatFromInt(f.freq_khz)) / 1e6}) catch break;
            fpos += piece.len;
        }
        s.putStr(net_row, net_col_start, "Freq: ", .bright_white, .default, .{ .bold = true });
        s.putStr(net_row, net_col_start + 6, freq_line[0..fpos], .cyan, .default, .{});
        net_row += 1;
    }
    if (power_info.valid and net_row < rows - 1) {
        const pw = std.fmt.bufPrint(&tmp, "Pwr:  Pkg:{d:.1}W Cor:{d:.1}W DDR:{d:.1}W",
            .{ power_info.package_w, power_info.core_w, power_info.dram_w }) catch "";
        s.putStr(net_row, net_col_start, pw, .magenta, .default, .{});
        net_row += 1;
    }

    // ── Process table (expanded with disk I/O + container columns) ────────────
    const proc_header_row: u16 = swap_row + 2;
    const ipc_available = procs.len > 0 and !std.math.isNan(procs[0].ipc);
    const disk_io_hot = procs.len > 0 and (procs[0].disk_read_kb_s > 10 or procs[0].disk_write_kb_s > 10);
    _ = disk_io_hot;

    // Column header
    s.putStr(proc_header_row, 0, "  PID", .black, .white, .{ .bold = true });
    s.putStr(proc_header_row, 6, " S", .black, .white, .{ .bold = true });
    s.putStr(proc_header_row, 9, "   CPU%", .black, .white, .{ .bold = true });
    s.putStr(proc_header_row, 17, "    RES", .black, .white, .{ .bold = true });
    var col_off: u16 = 25;
    if (ipc_available) {
        s.putStr(proc_header_row, col_off, "  IPC", .black, .white, .{ .bold = true });
        col_off += 6;
    }
    s.putStr(proc_header_row, col_off, "   R/s", .black, .white, .{ .bold = true });
    col_off += 7;
    s.putStr(proc_header_row, col_off, "   W/s", .black, .white, .{ .bold = true });
    col_off += 7;
    const name_col = col_off;
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

        const pid_s = std.fmt.bufPrint(&tmp, "{d:>5}", .{proc.pid}) catch "?????";
        s.putStr(row, 0, pid_s, row_fg, .default, .{});

        s.put(row, 6, .{ .ch = ' ', .fg = .default, .bg = .default, .attr = .{} });
        const state_fg: ansi.Color = switch (proc.state) {
            'R' => .green, 'D' => .red, 'Z' => .magenta, else => .default,
        };
        s.put(row, 7, .{ .ch = proc.state, .fg = state_fg, .bg = .default, .attr = .{} });

        const cpu_s = std.fmt.bufPrint(&tmp, " {d:6.1}%", .{proc.cpu_pct}) catch "       ";
        const cpu_fg: ansi.Color = if (proc.cpu_pct > 50.0) .red
            else if (proc.cpu_pct > 10.0) .yellow else .default;
        s.putStr(row, 9, cpu_s, cpu_fg, .default, .{});

        var res_buf: [16]u8 = undefined;
        const res_s = ansi.fmtKib(&res_buf, proc.rss_kb);
        const res_padded = std.fmt.bufPrint(&tmp, " {s:>6}", .{res_s}) catch "       ";
        s.putStr(row, 17, res_padded, .default, .default, .{});

        var c2 = col_off - 14;
        if (ipc_available) {
            var ipc_buf: [16]u8 = undefined;
            const ipc_s = if (std.math.isNan(proc.ipc)) "  N/A"
                else std.fmt.bufPrint(&ipc_buf, " {d:.2}", .{proc.ipc}) catch "  N/A";
            const ipc_fg: ansi.Color = if (std.math.isNan(proc.ipc)) .bright_black
                else if (proc.ipc > 3.0) .bright_green
                else if (proc.ipc > 1.5) .green else .yellow;
            s.putStr(row, 25, ipc_s, ipc_fg, .default, .{});
            c2 = 31;
        }

        // Disk R/W rates
        var dk1: [12]u8 = undefined;
        var dk2: [12]u8 = undefined;
        const dr_s = ansi.fmtKib(&dk1, @intFromFloat(proc.disk_read_kb_s * 1024));
        const dw_s = ansi.fmtKib(&dk2, @intFromFloat(proc.disk_write_kb_s * 1024));
        const dr_padded = std.fmt.bufPrint(&tmp, " {s:>5}", .{dr_s}) catch "      ";
        s.putStr(row, c2, dr_padded,
            if (proc.disk_read_kb_s > 1024) .yellow else .bright_black, .default, .{});
        const dw_padded = std.fmt.bufPrint(&tmp, " {s:>5}", .{dw_s}) catch "      ";
        s.putStr(row, c2 + 7, dw_padded,
            if (proc.disk_write_kb_s > 1024) .yellow else .bright_black, .default, .{});

        // TCP conn count badge (only if > 0, keeps table clean for non-networked procs)
        if (proc.tcp_conn_count > 0) {
            const tc_s = std.fmt.bufPrint(&tmp, " T{d}", .{proc.tcp_conn_count}) catch "";
            s.putStr(row, c2 + 14, tc_s, .cyan, .default, .{});
        }

        // Name + optional container badge
        const name = proc.nameSlice();
        if (proc.container_id_len > 0) {
            const ct_s = std.fmt.bufPrint(&tmp, " {s} [{s}]",
                .{ name, proc.container_id[0..proc.container_id_len] }) catch "";
            s.putStr(row, name_col, ct_s, .cyan, .default, .{});
        } else {
            const nd = std.fmt.bufPrint(&tmp, " {s}", .{name}) catch "";
            s.putStr(row, name_col, nd, row_fg, .default, .{});
        }
    }

    // ── Status bar at bottom ──────────────────────────────────────────────────
    if (rows > 1) {
        const tasks_s = std.fmt.bufPrint(&tmp,
            " Tasks: {d}  |  q:quit  r+arrows:rewind  ESC:live  :9090=REST",
            .{procs.len}) catch "";
        s.putStr(rows - 1, 0, tasks_s, .black, .bright_white, .{});
        for (tasks_s.len..@as(usize, cols)) |c| {
            s.put(rows - 1, @intCast(c), .{ .ch = ' ', .fg = .black, .bg = .bright_white, .attr = .{} });
        }
    }
}
