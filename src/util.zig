//! Low-level time utilities using Linux syscalls.
//! std.time.nanoTimestamp() and std.time.sleep() moved to std.Io in Zig 0.16.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

// Reads HOME or other env vars from /proc/self/environ.
// std.posix.getenv was removed in Zig 0.16.
pub fn getenv(name: []const u8) ?[]const u8 {
    const S = struct { var buf: [65536]u8 = undefined; };
    const fd = posix.openatZ(posix.AT.FDCWD, "/proc/self/environ",
        .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer _ = linux.close(@intCast(fd));
    const n = linux.read(@intCast(fd), &S.buf, S.buf.len);
    const len: usize = @intCast(@as(isize, @bitCast(n)));
    var i: usize = 0;
    while (i < len) {
        const entry_end = std.mem.indexOfScalarPos(u8, S.buf[0..len], i, 0) orelse len;
        const entry = S.buf[i..entry_end];
        if (std.mem.startsWith(u8, entry, name)) {
            const after = entry[name.len..];
            if (after.len > 0 and after[0] == '=') return after[1..];
        }
        i = entry_end + 1;
    }
    return null;
}

pub fn nanoTimestamp() i64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = linux.clock_gettime(.REALTIME, &ts);
    return ts.sec * 1_000_000_000 + ts.nsec;
}

pub fn sleep(ns: u64) void {
    var req = linux.timespec{
        .sec = @intCast(ns / 1_000_000_000),
        .nsec = @intCast(ns % 1_000_000_000),
    };
    var rem: linux.timespec = .{ .sec = 0, .nsec = 0 };
    while (true) {
        const ret = linux.nanosleep(&req, &rem);
        const r = @as(isize, @bitCast(ret));
        if (r != -4) break; // -4 = EINTR; retry with remainder
        req = rem;
    }
}
