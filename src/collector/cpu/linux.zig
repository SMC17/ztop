//! Linux CPU telemetry collector.
//!
//! Data sources:
//!   /proc/stat        — per-CPU tick counters
//!   /proc/meminfo     — memory breakdown
//!   /proc/loadavg     — load averages + uptime
//!   /proc/uptime      — uptime in seconds
//!   /proc/[pid]/stat  — per-process CPU + memory
//!   perf_event_open   — IPC + cache misses (requires paranoid≤1 or CAP_PERFMON)
//!
//! Zig 0.16: std.fs.cwd() is gone. Uses std.posix.openatZ + std.posix.read.

const std = @import("std");
const core = @import("core");
const util = @import("util");
const linux = std.os.linux;
const posix = std.posix;

pub const CollectError = error{
    ProcStatMissing,
    ProcMeminfoMissing,
    OutOfMemory,
};

// ── Raw proc file reader ──────────────────────────────────────────────────────

fn readProc(alloc: std.mem.Allocator, comptime path: [:0]const u8, max_size: usize) ![]u8 {
    const fd = try posix.openatZ(posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = linux.close(@intCast(fd));

    const buf = try alloc.alloc(u8, max_size);
    var total: usize = 0;
    while (total < max_size) {
        const n = try posix.read(fd, buf[total..]);
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}

fn readProcPath(alloc: std.mem.Allocator, path_z: [*:0]const u8, max_size: usize) ![]u8 {
    const fd = try posix.openatZ(posix.AT.FDCWD, path_z, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = linux.close(@intCast(fd));

    const buf = try alloc.alloc(u8, max_size);
    var total: usize = 0;
    while (total < max_size) {
        const n = try posix.read(fd, buf[total..]);
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}

// ── /proc/stat ────────────────────────────────────────────────────────────────

fn parseCpuLine(line: []const u8) ?core.CpuTick {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const tag = it.next() orelse return null;
    if (!std.mem.startsWith(u8, tag, "cpu")) return null;

    var t: core.CpuTick = .{};
    inline for (&[_]*u64{
        &t.user, &t.nice, &t.system, &t.idle,
        &t.iowait, &t.irq, &t.softirq, &t.steal,
    }) |field| {
        const tok = it.next() orelse break;
        field.* = std.fmt.parseInt(u64, tok, 10) catch 0;
    }
    return t;
}

pub fn collectCpuTicks(alloc: std.mem.Allocator) !struct {
    total: core.CpuTick,
    cores: []core.CpuTick,
} {
    const stat = try readProc(alloc, "/proc/stat", 256 * 1024);
    defer alloc.free(stat);

    var cores = std.ArrayListUnmanaged(core.CpuTick){ .items = &.{}, .capacity = 0 };
    var total: core.CpuTick = .{};
    var first = true;

    var lines = std.mem.tokenizeScalar(u8, stat, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "cpu")) break;
        const tick = parseCpuLine(line) orelse continue;
        if (first) {
            total = tick;
            first = false;
        } else {
            try cores.append(alloc, tick);
        }
    }

    return .{ .total = total, .cores = try cores.toOwnedSlice(alloc) };
}

// ── /proc/meminfo ─────────────────────────────────────────────────────────────

fn parseMemField(line: []const u8, key: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, line, key)) return null;
    const rest = line[key.len..];
    const trimmed = std.mem.trimStart(u8, rest, " \t:");
    const val_str = if (std.mem.endsWith(u8, trimmed, " kB"))
        trimmed[0 .. trimmed.len - 3]
    else
        trimmed;
    return std.fmt.parseInt(u64, std.mem.trim(u8, val_str, " "), 10) catch null;
}

pub const MemInfo = struct {
    total_kb: u64 = 0,
    free_kb: u64 = 0,
    available_kb: u64 = 0,
    cached_kb: u64 = 0,
    buffers_kb: u64 = 0,
    swap_total_kb: u64 = 0,
    swap_free_kb: u64 = 0,
};

pub fn collectMemInfo(alloc: std.mem.Allocator) !MemInfo {
    const data = try readProc(alloc, "/proc/meminfo", 32 * 1024);
    defer alloc.free(data);

    var m: MemInfo = .{};
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (parseMemField(line, "MemTotal:")) |v| { m.total_kb = v; continue; }
        if (parseMemField(line, "MemFree:")) |v| { m.free_kb = v; continue; }
        if (parseMemField(line, "MemAvailable:")) |v| { m.available_kb = v; continue; }
        if (parseMemField(line, "Cached:")) |v| { m.cached_kb = v; continue; }
        if (parseMemField(line, "Buffers:")) |v| { m.buffers_kb = v; continue; }
        if (parseMemField(line, "SwapTotal:")) |v| { m.swap_total_kb = v; continue; }
        if (parseMemField(line, "SwapFree:")) |v| { m.swap_free_kb = v; continue; }
    }
    return m;
}

// ── /proc/loadavg + /proc/uptime ─────────────────────────────────────────────

pub const SysInfo = struct {
    load_1: f32,
    load_5: f32,
    load_15: f32,
    uptime_s: u64,
};

pub fn collectSysInfo(alloc: std.mem.Allocator) !SysInfo {
    const load_data = try readProc(alloc, "/proc/loadavg", 256);
    defer alloc.free(load_data);

    var it = std.mem.tokenizeScalar(u8, load_data, ' ');
    const l1  = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0.0;
    const l5  = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0.0;
    const l15 = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0.0;

    const up_data = try readProc(alloc, "/proc/uptime", 64);
    defer alloc.free(up_data);
    var up_it = std.mem.tokenizeScalar(u8, up_data, ' ');
    const up_secs = std.fmt.parseFloat(f64, up_it.next() orelse "0") catch 0.0;

    return .{
        .load_1 = l1,
        .load_5 = l5,
        .load_15 = l15,
        .uptime_s = @intFromFloat(@max(0.0, up_secs)),
    };
}

// ── /proc/[pid]/stat ─────────────────────────────────────────────────────────

fn parsePidStat(data: []const u8, out: *core.ProcessInfo) bool {
    const lparen = std.mem.indexOfScalar(u8, data, '(') orelse return false;
    const rparen = std.mem.lastIndexOfScalar(u8, data, ')') orelse return false;
    if (rparen <= lparen) return false;

    const comm = data[lparen + 1 .. rparen];
    const copy_len = @min(comm.len, out.name.len - 1);
    @memcpy(out.name[0..copy_len], comm[0..copy_len]);
    out.name_len = @intCast(copy_len);

    var it = std.mem.tokenizeScalar(u8, data[rparen + 1 ..], ' ');
    const state_str = it.next() orelse return false;
    out.state = if (state_str.len > 0) state_str[0] else 'U';

    out.ppid = std.fmt.parseInt(u32, it.next() orelse "0", 10) catch 0;

    for (0..8) |_| _ = it.next();

    out.utime = std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0;
    out.stime = std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0;

    for (0..8) |_| _ = it.next();

    const rss_pages = std.fmt.parseInt(i64, it.next() orelse "0", 10) catch 0;
    out.rss_kb = @as(u64, @intCast(@max(0, rss_pages))) * 4;

    return true;
}

// ── /proc directory walk via getdents64 ──────────────────────────────────────

const linux_dirent64 = extern struct {
    d_ino: u64,
    d_off: i64,
    d_reclen: u16,
    d_type: u8,
    // d_name follows immediately (variable length)
};

fn iterProc(alloc: std.mem.Allocator, callback: anytype) !void {
    const fd = try posix.openatZ(posix.AT.FDCWD, "/proc", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    defer _ = linux.close(@intCast(fd));

    var dents_buf: [4096]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(@intCast(fd), &dents_buf, dents_buf.len);
        const n_signed = @as(isize, @bitCast(n));
        if (n_signed <= 0) break;

        var offset: usize = 0;
        while (offset < @as(usize, @intCast(n_signed))) {
            const ent: *const linux_dirent64 = @ptrCast(@alignCast(&dents_buf[offset]));
            offset += ent.d_reclen;

            // d_name starts right after the fixed part
            const name_ptr: [*:0]const u8 = @ptrCast(&dents_buf[offset - ent.d_reclen + @sizeOf(linux_dirent64)]);
            const name = std.mem.sliceTo(name_ptr, 0);

            // Only numeric entries (PIDs)
            const pid = std.fmt.parseInt(u32, name, 10) catch continue;
            try callback.call(alloc, pid);
        }
    }
}

// ── perf_event_open wrapper ───────────────────────────────────────────────────

const PERF_TYPE_HARDWARE: u32 = 0;
const PERF_COUNT_HW_INSTRUCTIONS: u64 = 1;
const PERF_COUNT_HW_CPU_CYCLES: u64 = 0;
const PERF_COUNT_HW_CACHE_MISSES: u64 = 5;
const PERF_COUNT_HW_BRANCH_MISSES: u64 = 7;
const PERF_FLAG_FD_CLOEXEC: u64 = 8;

const PerfEventAttr = extern struct {
    type: u32 = 0,
    size: u32 = 128,
    config: u64 = 0,
    sample_period_or_freq: u64 = 0,
    sample_type: u64 = 0,
    read_format: u64 = 0,
    flags: u64 = 0,
    wakeup_events_or_watermark: u32 = 0,
    bp_type: u32 = 0,
    bp_addr_or_config1: u64 = 0,
    bp_len_or_config2: u64 = 0,
    _pad: [48]u8 = [_]u8{0} ** 48,
};

fn perfOpen(pid: i32, config: u64, group_fd: i32) !i32 {
    var attr = PerfEventAttr{
        .type = PERF_TYPE_HARDWARE,
        .size = @sizeOf(PerfEventAttr),
        .config = config,
        .flags = (1 << 0) | (1 << 1),
    };
    const ret = linux.syscall5(
        .perf_event_open,
        @intFromPtr(&attr),
        @as(usize, @bitCast(@as(isize, pid))),
        @as(usize, @bitCast(@as(isize, -1))),
        @as(usize, @bitCast(@as(isize, group_fd))),
        PERF_FLAG_FD_CLOEXEC,
    );
    const fd = @as(i32, @intCast(@as(isize, @bitCast(ret))));
    if (fd < 0) return error.PerfOpenFailed;
    return fd;
}

fn perfEnable(fd: i32) void {
    _ = linux.syscall3(.ioctl, @as(usize, @intCast(fd)), 0x2400, 0);
    _ = linux.syscall3(.ioctl, @as(usize, @intCast(fd)), 0x2401, 0);
}

fn perfRead(fd: i32) u64 {
    var val: u64 = 0;
    _ = linux.read(@intCast(fd), @as([*]u8, @ptrCast(&val)), 8);
    return val;
}

pub const PerfCounters = struct {
    fd_instr: i32 = -1,
    fd_cycles: i32 = -1,
    fd_cache_miss: i32 = -1,
    fd_branch_miss: i32 = -1,

    pub fn open(pid: i32) PerfCounters {
        var p: PerfCounters = .{};
        p.fd_instr = perfOpen(pid, PERF_COUNT_HW_INSTRUCTIONS, -1) catch return p;
        p.fd_cycles = perfOpen(pid, PERF_COUNT_HW_CPU_CYCLES, p.fd_instr) catch {
            posix.close(p.fd_instr);
            p.fd_instr = -1;
            return p;
        };
        p.fd_cache_miss  = perfOpen(pid, PERF_COUNT_HW_CACHE_MISSES, p.fd_instr) catch p.fd_instr;
        p.fd_branch_miss = perfOpen(pid, PERF_COUNT_HW_BRANCH_MISSES, p.fd_instr) catch p.fd_instr;
        if (p.fd_instr >= 0) perfEnable(p.fd_instr);
        return p;
    }

    pub fn sample(self: *const PerfCounters) struct { ipc: f32, cache_miss_rate: f32 } {
        if (self.fd_instr < 0) return .{ .ipc = std.math.nan(f32), .cache_miss_rate = std.math.nan(f32) };
        const instr  = perfRead(self.fd_instr);
        const cycles = if (self.fd_cycles >= 0) perfRead(self.fd_cycles) else 0;
        const cmiss  = if (self.fd_cache_miss >= 0) perfRead(self.fd_cache_miss) else 0;
        const ipc: f32 = if (cycles == 0) 0.0
            else @as(f32, @floatFromInt(instr)) / @as(f32, @floatFromInt(cycles));
        const cmr: f32 = if (instr == 0) 0.0
            else @as(f32, @floatFromInt(cmiss)) * 1000.0 / @as(f32, @floatFromInt(instr));
        return .{ .ipc = ipc, .cache_miss_rate = cmr };
    }

    pub fn close(self: *PerfCounters) void {
        inline for (&[_]*i32{
            &self.fd_instr, &self.fd_cycles,
            &self.fd_cache_miss, &self.fd_branch_miss,
        }) |fd| {
            if (fd.* >= 0) {
                _ = linux.close(@intCast(fd.*));
                fd.* = -1;
            }
        }
    }
};

// ── Main collector ────────────────────────────────────────────────────────────

pub const Collector = struct {
    prev_total: core.CpuTick,
    prev_cores: []core.CpuTick,
    prev_proc_times: std.AutoHashMap(u32, u64),
    allocator: std.mem.Allocator,

    pub fn init(perm_alloc: std.mem.Allocator) !Collector {
        const cpudata = try collectCpuTicks(perm_alloc);
        return .{
            .prev_total = cpudata.total,
            .prev_cores = cpudata.cores,
            .prev_proc_times = std.AutoHashMap(u32, u64).init(perm_alloc),
            .allocator = perm_alloc,
        };
    }

    pub fn collect(self: *Collector, frame_alloc: std.mem.Allocator) !core.CpuSnapshot {
        const cpudata = try collectCpuTicks(frame_alloc);
        const mem = try collectMemInfo(frame_alloc);
        const sys = try collectSysInfo(frame_alloc);

        const core_pct = try frame_alloc.alloc(f32, cpudata.cores.len);
        for (cpudata.cores, 0..) |c, i| {
            const prev = if (i < self.prev_cores.len) self.prev_cores[i] else core.CpuTick{};
            core_pct[i] = core.CpuTick.pct(prev, c);
        }
        const total_pct = core.CpuTick.pct(self.prev_total, cpudata.total);

        self.allocator.free(self.prev_cores);
        self.prev_cores = try self.allocator.dupe(core.CpuTick, cpudata.cores);
        self.prev_total = cpudata.total;

        return .{
            .timestamp_ns = util.nanoTimestamp(),
            .cores = cpudata.cores,
            .total = cpudata.total,
            .core_pct = core_pct,
            .total_pct = total_pct,
            .mem_total_kb = mem.total_kb,
            .mem_free_kb = mem.free_kb,
            .mem_available_kb = mem.available_kb,
            .mem_cached_kb = mem.cached_kb,
            .mem_buffers_kb = mem.buffers_kb,
            .swap_total_kb = mem.swap_total_kb,
            .swap_free_kb = mem.swap_free_kb,
            .load_1 = sys.load_1,
            .load_5 = sys.load_5,
            .load_15 = sys.load_15,
            .uptime_s = sys.uptime_s,
        };
    }

    pub fn collectProcesses(
        self: *Collector,
        frame_alloc: std.mem.Allocator,
        snap: *const core.CpuSnapshot,
    ) ![]core.ProcessInfo {
        _ = snap;

        var procs = std.ArrayListUnmanaged(core.ProcessInfo){ .items = &.{}, .capacity = 0 };

        const ProcCallback = struct {
            procs: *std.ArrayListUnmanaged(core.ProcessInfo),
            collector: *Collector,
            frame_alloc: std.mem.Allocator,

            fn call(cb: @This(), alloc: std.mem.Allocator, pid: u32) !void {
                _ = alloc;
                var info: core.ProcessInfo = .{
                    .pid = pid,
                    .ppid = 0,
                    .name = [_]u8{0} ** 64,
                    .name_len = 0,
                    .state = 'U',
                    .utime = 0,
                    .stime = 0,
                    .cpu_pct = 0.0,
                    .vsize_kb = 0,
                    .rss_kb = 0,
                    .ipc = std.math.nan(f32),
                    .l1_miss_rate = std.math.nan(f32),
                    .l3_miss_rate = std.math.nan(f32),
                    .branch_miss_rate = std.math.nan(f32),
                };

                // Build zero-terminated path on stack
                var path_buf: [64]u8 = undefined;
                const path_s = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid}) catch return;
                if (path_s.len + 1 >= path_buf.len) return;
                path_buf[path_s.len] = 0;
                const path_z: [*:0]const u8 = path_buf[0..path_s.len :0];

                const stat_data = readProcPath(cb.frame_alloc, path_z, 4096) catch return;
                if (!parsePidStat(stat_data, &info)) return;

                const cur_time = info.utime + info.stime;
                const prev_time = cb.collector.prev_proc_times.get(pid) orelse cur_time;
                const delta: u64 = cur_time -| prev_time;
                info.cpu_pct = @as(f32, @floatFromInt(delta)) * 0.1;
                cb.collector.prev_proc_times.put(pid, cur_time) catch {};

                cb.procs.append(cb.frame_alloc, info) catch {};
            }
        };

        const cb = ProcCallback{
            .procs = &procs,
            .collector = self,
            .frame_alloc = frame_alloc,
        };
        try iterProc(frame_alloc, cb);

        const slice = try procs.toOwnedSlice(frame_alloc);
        std.mem.sort(core.ProcessInfo, slice, {}, struct {
            fn lt(_: void, a: core.ProcessInfo, b: core.ProcessInfo) bool {
                return b.cpu_pct < a.cpu_pct;
            }
        }.lt);

        return slice;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "parseCpuLine" {
    const line = "cpu0 12345 67 8901 234567 890 0 123 0 0 0";
    const t = parseCpuLine(line);
    try std.testing.expect(t != null);
    try std.testing.expectEqual(@as(u64, 12345), t.?.user);
    try std.testing.expectEqual(@as(u64, 234567), t.?.idle);
}

test "parseMemField" {
    const line = "MemTotal:       16189572 kB";
    const v = parseMemField(line, "MemTotal:");
    try std.testing.expect(v != null);
    try std.testing.expectEqual(@as(u64, 16189572), v.?);
}

test "collectCpuTicks smoke" {
    // Reads the live Linux procfs; nothing to read on other hosts.
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest; // needs Linux /proc
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try collectCpuTicks(arena.allocator());
    try std.testing.expect(result.total.total() > 0);
    try std.testing.expect(result.cores.len > 0);
}

test "collectMemInfo smoke" {
    // Reads the live Linux procfs; nothing to read on other hosts.
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest; // needs Linux /proc
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = try collectMemInfo(arena.allocator());
    try std.testing.expect(m.total_kb > 0);
    try std.testing.expect(m.available_kb <= m.total_kb);
}
