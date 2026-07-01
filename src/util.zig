//! Low-level time utilities using Linux syscalls.
//! std.time.nanoTimestamp() and std.time.sleep() moved to std.Io in Zig 0.16.

const linux = @import("std").os.linux;

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
