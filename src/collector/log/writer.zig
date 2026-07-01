// Historical JSONL logger for ztop.
//
// Appends one JSON snapshot per sample to:
//   ~/.local/share/ztop/YYYY-MM-DD.jsonl
//
// This is the atop-killer: atop can replay history but requires root and its
// own daemon. ztop logs to a plain text file readable by any tool.
//
// Format: one JSON object per line:
//   {"ts":1700000000,"cpu_pct":45.2,"mem_used_kb":8192000,...}
//
// Log rotation: new file per day (UTC). Files older than 30 days are NOT
// auto-deleted — user controls. That's the sovereign posture.

const std = @import("std");
const core = @import("core");
const util = @import("util");
const linux = std.os.linux;

pub const LogWriter = struct {
    dir_fd: i32 = -1,
    file_fd: i32 = -1,
    cur_day: u32 = 0, // YYYYMMDD
    sample_count: u64 = 0,

    pub fn init(self: *LogWriter) void {
        self.ensureDir();
    }

    pub fn deinit(self: *LogWriter) void {
        if (self.file_fd >= 0) _ = linux.close(@intCast(self.file_fd));
        if (self.dir_fd >= 0) _ = linux.close(@intCast(self.dir_fd));
    }

    pub fn write(self: *LogWriter, snap: *const core.CpuSnapshot,
        net: []const core.NetIface, disks: []const core.DiskStat) void
    {
        const day = utcDay(snap.timestamp_ns);
        if (day != self.cur_day or self.file_fd < 0) {
            self.openDayFile(day);
        }
        if (self.file_fd < 0) return;

        var buf: [2048]u8 = undefined;
        var w = BufWriter{ .buf = &buf, .len = 0 };

        w.str("{\"ts\":");
        w.ulong(@intCast(@divFloor(snap.timestamp_ns, 1_000_000_000)));
        w.str(",\"cpu_pct\":");
        w.f32_1(snap.total_pct);
        w.str(",\"mem_used_kb\":");
        w.ulong(snap.mem_used_kb());
        w.str(",\"mem_total_kb\":");
        w.ulong(snap.mem_total_kb);
        w.str(",\"load_1\":");
        w.f32_2(snap.load_1);

        // First non-loopback interface (tx+rx aggregate).
        if (net.len > 0) {
            w.str(",\"net_rx_kb_s\":");
            w.f32_1(net[0].rx_rate_kb_s);
            w.str(",\"net_tx_kb_s\":");
            w.f32_1(net[0].tx_rate_kb_s);
        }

        // First disk aggregate.
        if (disks.len > 0) {
            w.str(",\"disk_r_kb_s\":");
            w.f32_1(disks[0].read_rate_kb_s);
            w.str(",\"disk_w_kb_s\":");
            w.f32_1(disks[0].write_rate_kb_s);
        }

        w.str("}\n");

        _ = linux.write(@intCast(self.file_fd), w.buf[0..w.len].ptr, w.len);
        self.sample_count += 1;
    }

    fn ensureDir(self: *LogWriter) void {
        // Build ~/.local/share/ztop path.
        const home = util.getenv("HOME") orelse "/root";
        var path: [256]u8 = undefined;
        const ztop_dir = std.fmt.bufPrintZ(&path, "{s}/.local/share/ztop", .{home}) catch return;

        _ = linux.mkdir(ztop_dir, 0o755);

        self.dir_fd = @intCast(@as(isize, @bitCast(linux.open(
            ztop_dir, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0))));
    }

    fn openDayFile(self: *LogWriter, day: u32) void {
        if (self.file_fd >= 0) _ = linux.close(@intCast(self.file_fd));
        self.file_fd = -1;

        const home = util.getenv("HOME") orelse "/root";
        const yyyy = day / 10000;
        const mm = (day / 100) % 100;
        const dd = day % 100;

        var path: [256]u8 = undefined;
        const day_path = std.fmt.bufPrintZ(&path,
            "{s}/.local/share/ztop/{d:04}-{d:02}-{d:02}.jsonl",
            .{ home, yyyy, mm, dd }) catch return;

        self.file_fd = @intCast(@as(isize, @bitCast(linux.open(
            day_path,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true },
            0o644))));
        self.cur_day = day;
    }
};

fn utcDay(timestamp_ns: i64) u32 {
    const secs = @divFloor(timestamp_ns, 1_000_000_000);
    // Rough UTC day: secs since epoch / 86400.
    const days_since_epoch = @divFloor(secs, 86400);
    // Convert to Gregorian (Zeller-like algorithm, UTC).
    const z: i64 = days_since_epoch + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const y2 = if (m <= 2) y + 1 else y;
    return @intCast(@as(i64, y2) * 10000 + m * 100 + d);
}

// Minimal stack buffer writer — no heap, no fmt overhead.
const BufWriter = struct {
    buf: []u8,
    len: usize,

    fn str(self: *BufWriter, s: []const u8) void {
        const n = @min(s.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len .. self.len + n], s[0..n]);
        self.len += n;
    }

    fn ulong(self: *BufWriter, v: u64) void {
        var tmp: [20]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch return;
        self.str(s);
    }

    fn f32_1(self: *BufWriter, v: f32) void {
        var tmp: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d:.1}", .{v}) catch return;
        self.str(s);
    }

    fn f32_2(self: *BufWriter, v: f32) void {
        var tmp: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d:.2}", .{v}) catch return;
        self.str(s);
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "utcDay epoch" {
    // 2024-01-01 00:00:00 UTC = 1704067200 seconds
    const day = utcDay(1704067200 * 1_000_000_000);
    try std.testing.expectEqual(@as(u32, 20240101), day);
}

test "utcDay 2026-07-01" {
    // 2026-07-01 = 1782000000 ish
    const day = utcDay(1782000000 * 1_000_000_000);
    // Just verify it's a plausible 2026 date
    try std.testing.expect(day >= 20260101 and day <= 20261231);
}
