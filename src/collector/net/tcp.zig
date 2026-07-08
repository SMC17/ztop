// TCP connection table for ztop.
//
// Reads /proc/net/tcp (IPv4) and /proc/net/tcp6 (IPv6).
// Maps socket inodes to PIDs via /proc/PID/fd/ symlink scan.
// No root needed. Per-process conn count visible in process table.
//
// /proc/net/tcp format (fields space-separated):
//   sl local_addr:port rem_addr:port state ... inode
//   0: 00000000:1F40   00000000:0000  0A  ...   12345
// Addresses are little-endian hex (IPv4) or big-endian (IPv6).

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const core = @import("core");

pub const TcpState = enum(u8) {
    established = 0x01,
    syn_sent    = 0x02,
    syn_recv    = 0x03,
    fin_wait1   = 0x04,
    fin_wait2   = 0x05,
    time_wait   = 0x06,
    close       = 0x07,
    close_wait  = 0x08,
    last_ack    = 0x09,
    listen      = 0x0A,
    closing     = 0x0B,
    unknown     = 0xFF,

    pub fn fromHex(h: u8) TcpState {
        return switch (h) {
            0x01 => .established, 0x02 => .syn_sent, 0x03 => .syn_recv,
            0x04 => .fin_wait1,   0x05 => .fin_wait2, 0x06 => .time_wait,
            0x07 => .close,       0x08 => .close_wait, 0x09 => .last_ack,
            0x0A => .listen,      0x0B => .closing,    else => .unknown,
        };
    }

    pub fn name(self: TcpState) []const u8 {
        return switch (self) {
            .established => "ESTABLISHED", .syn_sent  => "SYN_SENT",
            .syn_recv    => "SYN_RECV",   .fin_wait1 => "FIN_WAIT1",
            .fin_wait2   => "FIN_WAIT2",  .time_wait => "TIME_WAIT",
            .close       => "CLOSE",      .close_wait => "CLOSE_WAIT",
            .last_ack    => "LAST_ACK",   .listen    => "LISTEN",
            .closing     => "CLOSING",    .unknown   => "UNKNOWN",
        };
    }
};

pub const TcpConn = struct {
    local_port:  u16,
    remote_port: u16,
    local_addr:  u32,  // IPv4, network byte order; 0 for IPv6
    remote_addr: u32,
    state: TcpState,
    pid: u32,          // 0 if inode not mapped
    inode: u64,
};

// Build inode→PID map by scanning /proc/PID/fd/ symlinks.
// Returns caller-owned map; deinit with .deinit() on the HashMap.
pub fn buildInodePidMap(alloc: std.mem.Allocator) std.AutoHashMap(u64, u32) {
    var map = std.AutoHashMap(u64, u32).init(alloc);

    const proc_fd = posix.openatZ(posix.AT.FDCWD, "/proc",
        .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0) catch return map;
    defer _ = linux.close(@intCast(proc_fd));

    var proc_buf: [65536]u8 = undefined;
    var proc_off: usize = 0;
    while (true) {
        const n: isize = @bitCast(linux.getdents64(
            @intCast(proc_fd), @ptrCast(&proc_buf[proc_off]),
            proc_buf.len - proc_off));
        if (n <= 0) break;
        var i: usize = 0;
        const chunk = proc_buf[0..@intCast(n)];
        while (i < chunk.len) {
            const ent: *linux.dirent64 = @ptrCast(@alignCast(&chunk[i]));
            i += ent.reclen;
            const nm = std.mem.sliceTo(@as([*:0]u8, @ptrCast(&ent.name)), 0);
            if (nm.len == 0 or nm[0] < '0' or nm[0] > '9') continue;
            const pid = std.fmt.parseInt(u32, nm, 10) catch continue;

            // Open /proc/<pid>/fd/
            var fd_path_buf: [32]u8 = undefined;
            const fd_path = std.fmt.bufPrintZ(&fd_path_buf, "/proc/{d}/fd", .{pid}) catch continue;
            const fd_dir = posix.openatZ(posix.AT.FDCWD, fd_path,
                .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0) catch continue;
            defer _ = linux.close(@intCast(fd_dir));

            var fd_buf: [32768]u8 = undefined;
            var fi: usize = 0;
            while (true) {
                const fn2: isize = @bitCast(linux.getdents64(
                    @intCast(fd_dir), @ptrCast(&fd_buf[fi]),
                    fd_buf.len - fi));
                if (fn2 <= 0) break;
                var j: usize = 0;
                const fchunk = fd_buf[0..@intCast(fn2)];
                while (j < fchunk.len) {
                    const fent: *linux.dirent64 = @ptrCast(@alignCast(&fchunk[j]));
                    j += fent.reclen;
                    const fn_name = std.mem.sliceTo(@as([*:0]u8, @ptrCast(&fent.name)), 0);
                    if (fn_name.len == 0) continue;

                    // readlinkat to check "socket:[inode]"
                    var link_buf: [128]u8 = undefined;
                    const link_len = posix.readlinkat(@intCast(fd_dir), fn_name, &link_buf) catch continue;
                    const link = link_buf[0..link_len];
                    if (!std.mem.startsWith(u8, link, "socket:[")) continue;
                    if (link.len < 10) continue;
                    const inode_str = link[8 .. link.len - 1]; // strip "socket:[" and "]"
                    const inode = std.fmt.parseInt(u64, inode_str, 10) catch continue;
                    map.put(inode, pid) catch {};
                }
            }
        }
        proc_off = 0;
    }
    return map;
}

// Parse one /proc/net/tcp or /proc/net/tcp6 line into a TcpConn.
// Returns null for the header line or parse failures.
fn parseTcpLine(line: []const u8, inode_pid: *const std.AutoHashMap(u64, u32)) ?TcpConn {
    var fields = std.mem.tokenizeAny(u8, line, " \t");
    _ = fields.next() orelse return null; // sl (index)
    const local_raw  = fields.next() orelse return null;
    const remote_raw = fields.next() orelse return null;
    const state_raw  = fields.next() orelse return null;
    // Skip tx_queue rx_queue tr tm->when retrnsmt uid timeout
    for (0..6) |_| _ = fields.next();
    const inode_raw = fields.next() orelse return null;

    // Skip "sl" header line (starts with non-hex or "sl")
    if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "sl")) return null;

    // Parse local addr:port
    const lcolon = std.mem.indexOfScalar(u8, local_raw, ':') orelse return null;
    const local_addr = std.fmt.parseInt(u32, local_raw[0..lcolon], 16) catch return null;
    const local_port: u16 = @intCast(std.fmt.parseInt(u32, local_raw[lcolon + 1..], 16) catch return null);

    // Parse remote addr:port
    const rcolon = std.mem.indexOfScalar(u8, remote_raw, ':') orelse return null;
    const remote_addr = std.fmt.parseInt(u32, remote_raw[0..rcolon], 16) catch return null;
    const remote_port: u16 = @intCast(std.fmt.parseInt(u32, remote_raw[rcolon + 1..], 16) catch return null);

    const state_byte = std.fmt.parseInt(u8, state_raw, 16) catch return null;
    const inode = std.fmt.parseInt(u64, inode_raw, 10) catch return null;

    if (inode == 0) return null; // TIME_WAIT entries have inode=0
    const pid = inode_pid.get(inode) orelse 0;

    return TcpConn{
        .local_port  = local_port,
        .remote_port = remote_port,
        .local_addr  = local_addr,
        .remote_addr = remote_addr,
        .state = TcpState.fromHex(state_byte),
        .pid   = pid,
        .inode = inode,
    };
}

// Collect all TCP connections from /proc/net/tcp (+ tcp6).
// Caller owns returned slice. inode_pid map must be built first (or null
// for no PID mapping — useful for global conn list).
pub fn collectTcp(alloc: std.mem.Allocator,
    inode_pid: *const std.AutoHashMap(u64, u32)) ![]TcpConn
{
    var conns: std.ArrayListUnmanaged(TcpConn) = .empty;

    const paths = [_][:0]const u8{ "/proc/net/tcp", "/proc/net/tcp6" };
    for (paths) |path| {
        const fd = posix.openatZ(posix.AT.FDCWD, path,
            .{ .ACCMODE = .RDONLY }, 0) catch continue;
        defer _ = linux.close(@intCast(fd));

        var buf: [131072]u8 = undefined;
        const n: isize = @bitCast(linux.read(@intCast(fd), &buf, buf.len - 1));
        if (n <= 0) continue;
        const data = buf[0..@intCast(n)];

        var lines = std.mem.tokenizeScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (parseTcpLine(line, inode_pid)) |conn| {
                try conns.append(alloc, conn);
            }
        }
    }
    return conns.toOwnedSlice(alloc);
}

// Count established connections per PID from a connection slice.
pub fn countPerPid(conns: []const TcpConn, pid: u32) u32 {
    var count: u32 = 0;
    for (conns) |c| {
        if (c.pid == pid and c.state == .established) count += 1;
    }
    return count;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "parseTcpLine skip header" {
    var map = std.AutoHashMap(u64, u32).init(std.testing.allocator);
    defer map.deinit();
    const header = "  sl  local_address rem_address   st tx_queue rx_queue";
    try std.testing.expect(parseTcpLine(header, &map) == null);
}

test "parseTcpLine established" {
    var map = std.AutoHashMap(u64, u32).init(std.testing.allocator);
    defer map.deinit();
    try map.put(99999, 1234);
    // Typical tcp line: sl=0, local=127.0.0.1:8080, remote=127.0.0.1:54321, state=01 (ESTABLISHED)
    const line = "   0: 0100007F:1F90 0100007F:D431 01 00000000:00000000 00:00000000 00000000  1000  0 99999 1 0000000000000000 20 4 24 10 -1";
    const conn = parseTcpLine(line, &map);
    try std.testing.expect(conn != null);
    try std.testing.expectEqual(TcpState.established, conn.?.state);
    try std.testing.expectEqual(@as(u16, 0x1F90), conn.?.local_port);
    try std.testing.expectEqual(@as(u32, 1234), conn.?.pid);
}
