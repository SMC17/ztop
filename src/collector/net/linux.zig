// Network I/O collector for ztop.
//
// Data source: /proc/net/dev
// Format: header lines, then per-interface:
//   iface: rx_bytes rx_pkts rx_errs ... tx_bytes tx_pkts tx_errs ...
//
// Computes delta rates per tick. Skips loopback.

const std = @import("std");
const core = @import("core");
const linux = std.os.linux;
const posix = std.posix;

fn readFile(alloc: std.mem.Allocator, path: [*:0]const u8) ![]u8 {
    const fd = try posix.openatZ(posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = linux.close(@intCast(fd));
    const buf = try alloc.alloc(u8, 64 * 1024);
    var total: usize = 0;
    while (total < buf.len) {
        const n = try posix.read(fd, buf[total..]);
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}

// Raw bytes from /proc/net/dev for one interface.
const RawIface = struct {
    name: [16]u8,
    name_len: u8,
    rx_bytes: u64,
    tx_bytes: u64,
    rx_packets: u64,
    tx_packets: u64,
    rx_errors: u64,
    tx_errors: u64,
};

pub fn collectNet(alloc: std.mem.Allocator) ![]core.NetIface {
    const data = readFile(alloc, "/proc/net/dev") catch return &.{};
    defer alloc.free(data);

    var result: std.ArrayListUnmanaged(core.NetIface) = .empty;
    errdefer result.deinit(alloc);

    var lines = std.mem.splitScalar(u8, data, '\n');
    // Skip first 2 header lines.
    _ = lines.next();
    _ = lines.next();

    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len == 0) continue;

        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const name = std.mem.trim(u8, trimmed[0..colon], " \t");

        // Skip loopback.
        if (std.mem.eql(u8, name, "lo")) continue;

        var it = std.mem.tokenizeScalar(u8, trimmed[colon + 1 ..], ' ');
        const rx_bytes  = std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0;
        const rx_pkts   = std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0;
        const rx_errs   = std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0;
        _ = it.next(); // drop
        _ = it.next(); // drop
        _ = it.next(); // drop
        _ = it.next(); // frame
        _ = it.next(); // compressed
        _ = it.next(); // multicast
        const tx_bytes  = std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0;
        const tx_pkts   = std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0;
        const tx_errs   = std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0;

        var iface = core.NetIface{
            .name = [_]u8{0} ** 16,
            .name_len = @intCast(@min(name.len, 15)),
            .rx_bytes = rx_bytes,
            .tx_bytes = tx_bytes,
            .rx_packets = rx_pkts,
            .tx_packets = tx_pkts,
            .rx_errors = rx_errs,
            .tx_errors = tx_errs,
            .rx_rate_kb_s = 0.0,
            .tx_rate_kb_s = 0.0,
        };
        @memcpy(iface.name[0..iface.name_len], name[0..iface.name_len]);
        try result.append(alloc, iface);
    }

    return result.toOwnedSlice(alloc);
}

// Stateful collector: tracks previous sample for delta rates.
pub const NetCollector = struct {
    prev: []core.NetIface,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) !NetCollector {
        return .{
            .prev = try collectNet(alloc),
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *NetCollector) void {
        self.alloc.free(self.prev);
    }

    pub fn collect(self: *NetCollector, frame_alloc: std.mem.Allocator, dt_s: f32) ![]core.NetIface {
        const curr = try collectNet(frame_alloc);

        for (curr) |*iface| {
            // Match by name against previous snapshot.
            for (self.prev) |*prev| {
                if (!std.mem.eql(u8, iface.name[0..iface.name_len], prev.name[0..prev.name_len])) continue;
                const drx = iface.rx_bytes -| prev.rx_bytes;
                const dtx = iface.tx_bytes -| prev.tx_bytes;
                if (dt_s > 0) {
                    iface.rx_rate_kb_s = @as(f32, @floatFromInt(drx)) / (dt_s * 1024.0);
                    iface.tx_rate_kb_s = @as(f32, @floatFromInt(dtx)) / (dt_s * 1024.0);
                }
                break;
            }
        }

        self.alloc.free(self.prev);
        self.prev = try self.alloc.dupe(core.NetIface, curr);
        return curr;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "collectNet smoke" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ifaces = try collectNet(arena.allocator());
    // Just verify it doesn't crash and returns reasonable data.
    for (ifaces) |iface| {
        try std.testing.expect(iface.name_len > 0);
        try std.testing.expect(iface.name_len <= 15);
    }
}
