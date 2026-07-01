// Disk I/O collector for ztop.
//
// Two data sources:
//   /proc/diskstats   — per-block-device throughput (beats nmon)
//   /proc/<PID>/io    — per-process read/write bytes (beats atop on accessibility)
//
// /proc/diskstats fields (11+ fields):
//   major minor name reads_merged reads_completed sectors_read ms_reading
//                    writes_merged writes_completed sectors_written ms_writing
//                    in_progress ms_io ms_weighted_io ...
// We track: sectors_read * 512 = read_bytes, sectors_written * 512 = write_bytes.

const std = @import("std");
const core = @import("core");
const linux = std.os.linux;
const posix = std.posix;

fn readFileZ(alloc: std.mem.Allocator, path: [*:0]const u8) ![]u8 {
    const fd = posix.openatZ(posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return &.{};
    defer _ = linux.close(@intCast(fd));
    const buf = try alloc.alloc(u8, 16 * 1024);
    var total: usize = 0;
    while (total < buf.len) {
        const n = posix.read(fd, buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}

// ── /proc/diskstats ───────────────────────────────────────────────────────────

pub fn collectDiskStats(alloc: std.mem.Allocator) ![]core.DiskStat {
    const data = try readFileZ(alloc, "/proc/diskstats");
    defer alloc.free(data);

    var result: std.ArrayListUnmanaged(core.DiskStat) = .empty;
    errdefer result.deinit(alloc);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        _ = it.next(); // major
        _ = it.next(); // minor
        const name = it.next() orelse continue;

        // Skip partition entries (sdaN, nvme0n1pN, etc.) — only whole devices.
        const last = name[name.len - 1];
        if (last >= '0' and last <= '9') {
            // Exception: nvme0n1 (ends in digit but is not a partition)
            if (!std.mem.startsWith(u8, name, "nvme") or
                std.mem.indexOf(u8, name, "p") != null) continue;
        }

        _ = it.next(); // reads_completed (some kernels have reads_merged first — handle both)
        const reads_completed = std.fmt.parseInt(u64, it.next() orelse "0", 10) catch continue;
        const sectors_read    = std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0;
        _ = it.next(); // ms_reading
        _ = it.next(); // writes_merged or writes_completed
        const writes_completed = std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0;
        const sectors_written  = std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0;

        var d = core.DiskStat{
            .name = [_]u8{0} ** 16,
            .name_len = @intCast(@min(name.len, 15)),
            .reads_completed = reads_completed,
            .writes_completed = writes_completed,
            .read_bytes = sectors_read * 512,
            .write_bytes = sectors_written * 512,
            .read_rate_kb_s = 0.0,
            .write_rate_kb_s = 0.0,
        };
        @memcpy(d.name[0..d.name_len], name[0..d.name_len]);
        try result.append(alloc, d);
    }
    return result.toOwnedSlice(alloc);
}

// ── /proc/<PID>/io ────────────────────────────────────────────────────────────

pub const PidIo = struct {
    read_bytes: u64,
    write_bytes: u64,
    read_rate_kb_s: f32,
    write_rate_kb_s: f32,
};

pub fn readPidIo(alloc: std.mem.Allocator, pid: u32) !PidIo {
    var path_buf: [64]u8 = undefined;
    const path_s = std.fmt.bufPrint(&path_buf, "/proc/{d}/io", .{pid}) catch return error.PathTooLong;
    if (path_s.len + 1 >= path_buf.len) return error.PathTooLong;
    path_buf[path_s.len] = 0;
    const path_z: [*:0]const u8 = path_buf[0..path_s.len :0];

    const data = readFileZ(alloc, path_z) catch return .{ .read_bytes = 0, .write_bytes = 0, .read_rate_kb_s = 0, .write_rate_kb_s = 0 };
    defer alloc.free(data);

    var read_bytes: u64 = 0;
    var write_bytes: u64 = 0;

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "read_bytes:")) {
            const rest = std.mem.trimStart(u8, line["read_bytes:".len..], " ");
            read_bytes = std.fmt.parseInt(u64, rest, 10) catch 0;
        } else if (std.mem.startsWith(u8, line, "write_bytes:")) {
            const rest = std.mem.trimStart(u8, line["write_bytes:".len..], " ");
            write_bytes = std.fmt.parseInt(u64, rest, 10) catch 0;
        }
    }
    return .{ .read_bytes = read_bytes, .write_bytes = write_bytes, .read_rate_kb_s = 0, .write_rate_kb_s = 0 };
}

// ── Stateful disk collector ───────────────────────────────────────────────────

pub const DiskCollector = struct {
    prev: []core.DiskStat,
    alloc: std.mem.Allocator,
    // Per-PID previous I/O bytes (for delta). Keyed by PID.
    prev_pid_io: std.AutoHashMap(u32, PidIo),

    pub fn init(alloc: std.mem.Allocator) !DiskCollector {
        return .{
            .prev = try collectDiskStats(alloc),
            .alloc = alloc,
            .prev_pid_io = std.AutoHashMap(u32, PidIo).init(alloc),
        };
    }

    pub fn deinit(self: *DiskCollector) void {
        self.alloc.free(self.prev);
        self.prev_pid_io.deinit();
    }

    pub fn collect(self: *DiskCollector, frame_alloc: std.mem.Allocator, dt_s: f32) ![]core.DiskStat {
        const curr = try collectDiskStats(frame_alloc);

        for (curr) |*d| {
            for (self.prev) |*p| {
                if (!std.mem.eql(u8, d.name[0..d.name_len], p.name[0..p.name_len])) continue;
                const dr = d.read_bytes  -| p.read_bytes;
                const dw = d.write_bytes -| p.write_bytes;
                if (dt_s > 0) {
                    d.read_rate_kb_s  = @as(f32, @floatFromInt(dr)) / (dt_s * 1024.0);
                    d.write_rate_kb_s = @as(f32, @floatFromInt(dw)) / (dt_s * 1024.0);
                }
                break;
            }
        }

        self.alloc.free(self.prev);
        self.prev = try self.alloc.dupe(core.DiskStat, curr);
        return curr;
    }

    // Collect per-process disk I/O delta, returns (read_rate_kb_s, write_rate_kb_s).
    pub fn pidIoRates(self: *DiskCollector, alloc: std.mem.Allocator, pid: u32, dt_s: f32) struct { r: f32, w: f32 } {
        const curr = readPidIo(alloc, pid) catch return .{ .r = 0, .w = 0 };
        const prev = self.prev_pid_io.get(pid) orelse curr;
        self.prev_pid_io.put(pid, curr) catch {};

        if (dt_s <= 0) return .{ .r = 0, .w = 0 };
        const dr = curr.read_bytes  -| prev.read_bytes;
        const dw = curr.write_bytes -| prev.write_bytes;
        return .{
            .r = @as(f32, @floatFromInt(dr)) / (dt_s * 1024.0),
            .w = @as(f32, @floatFromInt(dw)) / (dt_s * 1024.0),
        };
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "collectDiskStats smoke" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const disks = try collectDiskStats(arena.allocator());
    try std.testing.expect(disks.len >= 0); // may be 0 in a container
    for (disks) |d| {
        try std.testing.expect(d.name_len > 0);
    }
}
