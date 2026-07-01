//! ztop-g — Zig-native GPU monitor (nvtop successor).
//!
//! Architecture:
//!   GpuPoller (background thread) → atomic double-buffer → render loop
//!   UI thread never blocks on NVML.
//!
//! Differentiators vs nvtop:
//!   - Per-PID VRAM velocity (OOM prediction) — a rate, not a snapshot
//!   - SM clock + PCIe TX/RX breakdown in the same view
//!   - Pure Zig: no ncurses, no libdrm dep for NVIDIA path
//!   - Zero alloc in render path (arena reset each tick)

const std = @import("std");
const core = @import("core");
const gpu  = @import("gpu");
const util = @import("util");
const ansi = @import("ui/ansi.zig");

var should_exit = std.atomic.Value(bool).init(false);

fn onSigint(_: std.os.linux.SIG) callconv(.c) void {
    should_exit.store(true, .release);
}

fn onSigwinch(_: std.os.linux.SIG) callconv(.c) void {
    resize_pending.store(true, .release);
}
var resize_pending = std.atomic.Value(bool).init(false);

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const perm_alloc = gpa.allocator();

    // Signal handlers
    const linux = std.os.linux;
    var sa_int: linux.Sigaction = .{
        .handler = .{ .handler = onSigint },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(linux.SIG.INT, &sa_int, null);
    var sa_winch: linux.Sigaction = .{
        .handler = .{ .handler = onSigwinch },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(linux.SIG.WINCH, &sa_winch, null);

    // Start GPU poller
    var poller = try gpu.GpuPoller.start(perm_alloc);
    defer poller.stop();

    if (!poller.available) {
        _ = std.os.linux.write(2, "ztop-g: No NVIDIA GPU found or driver not loaded.\n", 51);
        _ = std.os.linux.write(2, "        Requires: libnvidia-ml.so + /dev/nvidia0\n", 50);
        return;
    }

    // Init screen
    var screen = try ansi.Screen.init(perm_alloc);
    defer screen.deinit();
    screen.enterAlt();
    defer screen.exitAlt();

    // VRAM history per device (ring buffer for velocity sparkline)
    var vram_history: [gpu.MAX_DEVICES]core.HistoryBuf = undefined;
    for (&vram_history) |*h| h.* = core.HistoryBuf.init();

    // Raw mode stdin
    const stdin_fd = std.posix.STDIN_FILENO;
    const old_termios = try std.posix.tcgetattr(stdin_fd);
    var raw = old_termios;
    raw.lflag.ECHO   = false;
    raw.lflag.ICANON = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)]  = 0;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(stdin_fd, .NOW, raw);
    defer std.posix.tcsetattr(stdin_fd, .NOW, old_termios) catch {};

    var arena = std.heap.ArenaAllocator.init(perm_alloc);
    defer arena.deinit();

    while (!should_exit.load(.acquire)) {
        _ = arena.reset(.retain_capacity);

        if (resize_pending.cmpxchgStrong(true, false, .acq_rel, .acquire) == null) {
            screen.resize();
        }

        // Non-blocking key read
        var key_buf: [4]u8 = undefined;
        const nread = std.posix.read(stdin_fd, &key_buf) catch 0;
        if (nread > 0 and (key_buf[0] == 'q' or key_buf[0] == 3)) {
            should_exit.store(true, .release);
        }

        const frame = gpu.readLatest();

        screen.clear();
        renderGpuFrame(&screen, frame, &vram_history);
        try screen.flush();

        util.sleep(500_000_000); // 2Hz
    }
}

fn renderGpuFrame(
    s: *ansi.Screen,
    frame: *const gpu.GpuFrame,
    vram_history: *[gpu.MAX_DEVICES]core.HistoryBuf,
) void {
    const cols = s.cols;
    const rows = s.rows;
    var tmp: [256]u8 = undefined;

    // ── Header ────────────────────────────────────────────────────────────────
    const hdr = std.fmt.bufPrint(&tmp,
        " ztop-g v0.0.1  |  {d} GPU(s)  |  q:quit",
        .{frame.device_count}) catch " ztop-g";
    s.putStr(0, 0, hdr, .black, .magenta, .{ .bold = true });
    for (hdr.len..@as(usize, cols)) |c| {
        s.put(0, @intCast(c), .{ .ch = ' ', .fg = .black, .bg = .magenta, .attr = .{} });
    }

    var row: u16 = 1;

    for (frame.devices[0..frame.device_count]) |dev| {
        if (row + 8 >= rows) break;

        // ── Device header bar ─────────────────────────────────────────────────
        const dev_hdr = std.fmt.bufPrint(&tmp,
            " GPU{d}: {s}",
            .{ dev.index, dev.nameSlice() }) catch " GPU?";
        s.putStr(row, 0, dev_hdr, .black, .cyan, .{});
        for (dev_hdr.len..@as(usize, cols)) |c| {
            s.put(row, @intCast(c), .{ .ch = ' ', .fg = .black, .bg = .cyan, .attr = .{} });
        }
        row += 1;

        // ── GPU utilization bar ───────────────────────────────────────────────
        const bar_width: u16 = if (cols > 50) cols / 3 else 20;
        {
            const pct = @as(f32, @floatFromInt(dev.util_gpu));
            const fg: ansi.Color = if (pct > 90.0) .red else if (pct > 60.0) .yellow else .green;
            s.putStr(row, 0, " GPU  [", .bright_white, .default, .{});
            s.putBar(row, 7, bar_width, pct, fg, .default);
            s.putStr(row, 7 + bar_width, "]", .default, .default, .{});
            const pct_s = std.fmt.bufPrint(&tmp, " {d:3}%", .{dev.util_gpu}) catch "";
            s.putStr(row, 8 + bar_width, pct_s, fg, .default, .{});

            // SM clock on the right
            const sm_s = std.fmt.bufPrint(&tmp, " SM:{d}MHz", .{dev.sm_clock_mhz}) catch "";
            if (8 + bar_width + 6 + sm_s.len < @as(usize, cols)) {
                s.putStr(row, 8 + bar_width + 6, sm_s, .bright_cyan, .default, .{});
            }
        }
        row += 1;

        // ── Memory bar ───────────────────────────────────────────────────────
        {
            const pct = dev.vram_pct();
            const fg: ansi.Color = if (pct > 90.0) .red else if (pct > 70.0) .yellow else .cyan;
            s.putStr(row, 0, " VRAM [", .bright_white, .default, .{});
            s.putBar(row, 7, bar_width, pct, fg, .default);
            s.putStr(row, 7 + bar_width, "]", .default, .default, .{});
            var m1: [16]u8 = undefined;
            var m2: [16]u8 = undefined;
            const used_s = ansi.fmtKib(&m1, dev.vram_used_mib * 1024);
            const total_s = ansi.fmtKib(&m2, dev.vram_total_mib * 1024);
            const mem_s = std.fmt.bufPrint(&tmp, " {s}/{s}", .{ used_s, total_s }) catch "";
            s.putStr(row, 8 + bar_width, mem_s, fg, .default, .{});

            // Mem clock right side
            const mc_s = std.fmt.bufPrint(&tmp, " MEM:{d}MHz", .{dev.mem_clock_mhz}) catch "";
            if (8 + bar_width + 12 + mc_s.len < @as(usize, cols)) {
                s.putStr(row, 8 + bar_width + 12, mc_s, .bright_cyan, .default, .{});
            }
        }
        row += 1;

        // ── Thermal + power + PCIe row ────────────────────────────────────────
        {
            const pwr_pct = dev.power_pct();
            const temp_fg: ansi.Color = if (dev.temp_c > 85) .red
                else if (dev.temp_c > 70) .yellow else .green;

            const stats = std.fmt.bufPrint(&tmp,
                " Temp:{d}°C  Pwr:{d}W/{d}W ({d:.0}%)  PCIe TX:{d}KB/s RX:{d}KB/s",
                .{ dev.temp_c,
                   dev.power_mw / 1000, dev.power_limit_mw / 1000, pwr_pct,
                   dev.pcie_tx_kb, dev.pcie_rx_kb }) catch "";
            s.putStr(row, 0, stats, temp_fg, .default, .{});
        }
        row += 1;

        // ── VRAM sparkline ────────────────────────────────────────────────────
        {
            // Push synthetic VRAM% into history using the core HistoryBuf
            // by building a fake CpuSnapshot where total_pct = vram_pct
            const fake_snap = core.CpuSnapshot{
                .timestamp_ns = frame.timestamp_ns,
                .cores = &.{},
                .total = .{},
                .core_pct = &.{},
                .total_pct = dev.vram_pct(),
                .mem_total_kb = dev.vram_total_mib * 1024,
                .mem_free_kb = (dev.vram_total_mib -| dev.vram_used_mib) * 1024,
                .mem_available_kb = (dev.vram_total_mib -| dev.vram_used_mib) * 1024,
                .mem_cached_kb = 0,
                .mem_buffers_kb = 0,
                .swap_total_kb = 0,
                .swap_free_kb = 0,
                .load_1 = 0, .load_5 = 0, .load_15 = 0,
                .uptime_s = 0,
            };
            vram_history[dev.index].push(fake_snap);

            const spark_width: u16 = if (cols > 10) cols - 10 else 10;
            s.putStr(row, 0, " VRAM:", .bright_white, .default, .{});
            var spark_buf: [1800]f32 = undefined;
            const n_s = vram_history[dev.index].lastN(@as(usize, spark_width), spark_buf[0..]);
            s.putSparkline(row, 6, spark_width, spark_buf[0..n_s]);
        }
        row += 1;

        // ── Per-process VRAM table ────────────────────────────────────────────
        if (dev.processes.len > 0) {
            s.putStr(row, 2, "  PID  VRAM      Vel(MiB/s)", .black, .white, .{});
            for (2 + 28..@as(usize, cols)) |c| {
                s.put(row, @intCast(c), .{ .ch = ' ', .fg = .black, .bg = .white, .attr = .{} });
            }
            row += 1;

            const max_proc = @min(dev.processes.len, 4);
            for (dev.processes[0..max_proc]) |proc| {
                const vel = proc.vram_velocity_mib_s;
                const vel_fg: ansi.Color = if (vel > 100.0) .red
                    else if (vel > 10.0) .yellow
                    else if (vel < -10.0) .bright_black // shrinking
                    else .default;

                const proc_s = std.fmt.bufPrint(&tmp,
                    "  {d:>5}  {d:>5}MiB  {s}{d:.1}",
                    .{ proc.pid, proc.vram_used_mib,
                       if (vel >= 0) "+" else "", vel }) catch "";
                s.putStr(row, 0, proc_s, vel_fg, .default, .{});
                row += 1;
                if (row >= rows - 2) break;
            }
        }

        row += 1; // gap between devices
    }

    // ── No GPU fallback ───────────────────────────────────────────────────────
    if (frame.device_count == 0 and row < rows - 2) {
        s.putStr(row, 2, "No NVIDIA GPUs detected.", .yellow, .default, .{});
    }

    // ── Status bar ───────────────────────────────────────────────────────────
    if (rows > 1) {
        const status = std.fmt.bufPrint(&tmp,
            " Poll: 200ms | NVML v595 | q:quit ", .{}) catch "";
        s.putStr(rows - 1, 0, status, .black, .bright_white, .{});
        for (status.len..@as(usize, cols)) |c| {
            s.put(rows - 1, @intCast(c), .{ .ch = ' ', .fg = .black, .bg = .bright_white, .attr = .{} });
        }
    }
}
