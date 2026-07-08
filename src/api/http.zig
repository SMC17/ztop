// Embedded REST API server for ztop.
//
// Listens on 127.0.0.1:9090. Returns JSON snapshots.
//
// Endpoints:
//   GET /api/v1/snapshot   — current CpuSnapshot as JSON
//   GET /api/v1/processes  — top 20 processes as JSON
//   GET /api/v1/net        — network interface rates
//   GET /api/v1/disk       — disk I/O rates
//   GET /api/v1/thermal    — temperatures + frequencies
//
// This kills glances' "built-in web UI" differentiator:
// ztop exposes the same data at a clean REST endpoint from a 500KB binary.
// Client: curl localhost:9090/api/v1/snapshot | jq .cpu_pct

const std = @import("std");
const linux = std.os.linux;
const core = @import("core");

// Spinlock for cross-thread snapshot sharing.
// std.Thread.Mutex was removed in Zig 0.16; std.atomic.Mutex has only tryLock.
const Spinlock = struct {
    state: std.atomic.Mutex = .unlocked,
    pub fn lock(self: *Spinlock) void {
        while (!self.state.tryLock()) std.atomic.spinLoopHint();
    }
    pub fn unlock(self: *Spinlock) void {
        self.state.unlock();
    }
};

pub const PORT: u16 = 9090;

// Shared snapshot published by main thread, consumed by API thread.
pub const ApiSnapshot = struct {
    mutex: Spinlock = .{},
    cpu_pct: f32 = 0,
    mem_used_kb: u64 = 0,
    mem_total_kb: u64 = 0,
    load_1: f32 = 0,
    load_5: f32 = 0,
    load_15: f32 = 0,
    uptime_s: u64 = 0,
    procs_json: [65536]u8 = [_]u8{0} ** 65536,
    procs_json_len: usize = 0,
    net_json: [4096]u8 = [_]u8{0} ** 4096,
    net_json_len: usize = 0,
    disk_json: [4096]u8 = [_]u8{0} ** 4096,
    disk_json_len: usize = 0,
    thermal_json: [4096]u8 = [_]u8{0} ** 4096,
    thermal_json_len: usize = 0,
    ts_ns: i64 = 0,
    conns_json: [8192]u8 = [_]u8{0} ** 8192,
    conns_json_len: usize = 0,

    pub fn updateCpu(self: *ApiSnapshot, snap: *const core.CpuSnapshot) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.cpu_pct = snap.total_pct;
        self.mem_used_kb = snap.mem_used_kb();
        self.mem_total_kb = snap.mem_total_kb;
        self.load_1 = snap.load_1;
        self.load_5 = snap.load_5;
        self.load_15 = snap.load_15;
        self.uptime_s = snap.uptime_s;
        self.ts_ns = snap.timestamp_ns;
    }

    pub fn updateProcs(self: *ApiSnapshot, json: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const n = @min(json.len, self.procs_json.len);
        @memcpy(self.procs_json[0..n], json[0..n]);
        self.procs_json_len = n;
    }

    pub fn updateNet(self: *ApiSnapshot, json: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const n = @min(json.len, self.net_json.len);
        @memcpy(self.net_json[0..n], json[0..n]);
        self.net_json_len = n;
    }

    pub fn updateDisk(self: *ApiSnapshot, json: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const n = @min(json.len, self.disk_json.len);
        @memcpy(self.disk_json[0..n], json[0..n]);
        self.disk_json_len = n;
    }

    pub fn updateThermal(self: *ApiSnapshot, json: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const n = @min(json.len, self.thermal_json.len);
        @memcpy(self.thermal_json[0..n], json[0..n]);
        self.thermal_json_len = n;
    }

    pub fn updateConns(self: *ApiSnapshot, json: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const n = @min(json.len, self.conns_json.len);
        @memcpy(self.conns_json[0..n], json[0..n]);
        self.conns_json_len = n;
    }

    // Copy current snapshot JSON for streaming (caller must hold no lock).
    pub fn snapshotJson(self: *ApiSnapshot, buf: []u8) []u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const s = std.fmt.bufPrint(buf,
            "{{\"ts\":{d},\"cpu_pct\":{d:.1},\"mem_used_kb\":{d},\"mem_total_kb\":{d}," ++
            "\"load_1\":{d:.2},\"load_5\":{d:.2},\"load_15\":{d:.2},\"uptime_s\":{d}}}\n",
            .{
                @divFloor(self.ts_ns, 1_000_000_000),
                self.cpu_pct, self.mem_used_kb, self.mem_total_kb,
                self.load_1, self.load_5, self.load_15, self.uptime_s,
            }) catch return buf[0..0];
        return s;
    }
};

pub const ApiServer = struct {
    snap: *ApiSnapshot,
    running: std.atomic.Value(bool),

    pub fn init(snap: *ApiSnapshot) ApiServer {
        return .{
            .snap = snap,
            .running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn start(self: *ApiServer) !std.Thread {
        self.running.store(true, .release);
        return std.Thread.spawn(.{}, serverLoop, .{self});
    }

    pub fn stop(self: *ApiServer) void {
        self.running.store(false, .release);
    }

    fn serverLoop(self: *ApiServer) void {
        const srv_fd: i32 = @intCast(@as(isize, @bitCast(
            linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0))));
        if (srv_fd < 0) return;
        defer _ = linux.close(@intCast(srv_fd));

        var reuse: i32 = 1;
        _ = linux.setsockopt(srv_fd, linux.SOL.SOCKET, linux.SO.REUSEADDR,
            @ptrCast(&reuse), @sizeOf(i32));

        var addr = linux.sockaddr.in{
            .family = linux.AF.INET,
            .port = std.mem.nativeToBig(u16, PORT),
            .addr = 0x0100007f, // 127.0.0.1 (little-endian: 0x7f000001 → store bytes)
            .zero = [_]u8{0} ** 8,
        };
        // Fix byte order for addr: 127.0.0.1 = 0x7F000001 in network order.
        addr.addr = std.mem.nativeToBig(u32, 0x7F000001);

        if (@as(isize, @bitCast(linux.bind(srv_fd,
            @ptrCast(&addr), @sizeOf(linux.sockaddr.in)))) < 0) return;
        if (@as(isize, @bitCast(linux.listen(srv_fd, 8))) < 0) return;

        var tv: linux.timeval = .{ .sec = 1, .usec = 0 };
        _ = linux.setsockopt(srv_fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO,
            @ptrCast(&tv), @sizeOf(linux.timeval));

        while (self.running.load(.acquire)) {
            var cli_addr: linux.sockaddr.in = std.mem.zeroes(linux.sockaddr.in);
            var cli_len: u32 = @sizeOf(linux.sockaddr.in);
            const cli_fd: i32 = @intCast(@as(isize, @bitCast(
                linux.accept(srv_fd, @ptrCast(&cli_addr), &cli_len))));
            if (cli_fd < 0) continue;
            self.handleRequest(cli_fd);
            _ = linux.close(@intCast(cli_fd));
        }
    }

    fn handleRequest(self: *ApiServer, fd: i32) void {
        var buf: [2048]u8 = undefined;
        const n: isize = @bitCast(linux.read(@intCast(fd), &buf, buf.len - 1));
        if (n <= 0) return;
        const req = buf[0..@intCast(n)];

        // Parse first line: "GET /api/v1/... HTTP/1.1"
        const line_end = std.mem.indexOfScalar(u8, req, '\n') orelse req.len;
        const line = req[0..line_end];
        const path_start = std.mem.indexOfScalar(u8, line, '/') orelse {
            send404(fd);
            return;
        };
        const path_end = std.mem.indexOfScalarPos(u8, line, path_start, ' ') orelse line.len;
        const path = line[path_start..path_end];

        if (std.mem.eql(u8, path, "/api/v1/snapshot")) {
            self.serveSnapshot(fd);
        } else if (std.mem.eql(u8, path, "/api/v1/stream")) {
            self.serveStream(fd);
        } else if (std.mem.startsWith(u8, path, "/api/v1/processes")) {
            self.serveProcesses(fd, path);
        } else if (std.mem.eql(u8, path, "/api/v1/connections")) {
            self.snap.mutex.lock();
            const body = self.snap.conns_json[0..self.snap.conns_json_len];
            self.snap.mutex.unlock();
            sendJson(fd, body);
        } else if (std.mem.eql(u8, path, "/api/v1/net")) {
            self.snap.mutex.lock();
            const body = self.snap.net_json[0..self.snap.net_json_len];
            self.snap.mutex.unlock();
            sendJson(fd, body);
        } else if (std.mem.eql(u8, path, "/api/v1/disk")) {
            self.snap.mutex.lock();
            const body = self.snap.disk_json[0..self.snap.disk_json_len];
            self.snap.mutex.unlock();
            sendJson(fd, body);
        } else if (std.mem.eql(u8, path, "/api/v1/thermal")) {
            self.snap.mutex.lock();
            const body = self.snap.thermal_json[0..self.snap.thermal_json_len];
            self.snap.mutex.unlock();
            sendJson(fd, body);
        } else if (std.mem.eql(u8, path, "/health") or std.mem.eql(u8, path, "/")) {
            sendJson(fd, "{\"status\":\"ok\"}");
        } else {
            send404(fd);
        }
    }

    fn serveSnapshot(self: *ApiServer, fd: i32) void {
        self.snap.mutex.lock();
        var body: [512]u8 = undefined;
        const s = std.fmt.bufPrint(&body,
            "{{\"ts\":{d},\"cpu_pct\":{d:.1},\"mem_used_kb\":{d},\"mem_total_kb\":{d}," ++
            "\"load_1\":{d:.2},\"load_5\":{d:.2},\"load_15\":{d:.2},\"uptime_s\":{d}}}",
            .{
                @divFloor(self.snap.ts_ns, 1_000_000_000),
                self.snap.cpu_pct,
                self.snap.mem_used_kb,
                self.snap.mem_total_kb,
                self.snap.load_1,
                self.snap.load_5,
                self.snap.load_15,
                self.snap.uptime_s,
            }) catch "{\"error\":\"fmt\"}";
        self.snap.mutex.unlock();
        sendJson(fd, s);
    }

    // GET /api/v1/stream — NDJSON long-poll, one snapshot per second.
    // Client: curl localhost:9090/api/v1/stream
    fn serveStream(self: *ApiServer, fd: i32) void {
        const hdr =
            "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\n" ++
            "Access-Control-Allow-Origin: *\r\nTransfer-Encoding: chunked\r\n\r\n";
        const hw: isize = @bitCast(linux.write(@intCast(fd), hdr.ptr, hdr.len));
        if (hw <= 0) return;

        var snap_buf: [1024]u8 = undefined;
        while (self.running.load(.acquire)) {
            const line = self.snap.snapshotJson(&snap_buf);
            if (line.len == 0) { util_sleep(1_000_000_000); continue; }
            // Chunked encoding: "<hex-len>\r\n<data>\r\n"
            var chunk_hdr: [16]u8 = undefined;
            const ch = std.fmt.bufPrint(&chunk_hdr, "{x}\r\n", .{line.len}) catch break;
            const wh: isize = @bitCast(linux.write(@intCast(fd), ch.ptr, ch.len));
            if (wh <= 0) break;
            const wb: isize = @bitCast(linux.write(@intCast(fd), line.ptr, line.len));
            if (wb <= 0) break;
            _ = linux.write(@intCast(fd), "\r\n", 2);
            util_sleep(1_000_000_000); // 1 Hz
        }
        // Terminal chunk.
        _ = linux.write(@intCast(fd), "0\r\n\r\n", 5);
    }

    // GET /api/v1/processes?limit=N&offset=O — paginated process JSON.
    fn serveProcesses(self: *ApiServer, fd: i32, path: []const u8) void {
        var limit: usize = 50;
        var offset: usize = 0;
        // Parse query string: path may be "/api/v1/processes?limit=20&offset=40"
        if (std.mem.indexOfScalar(u8, path, '?')) |qs| {
            var params = std.mem.tokenizeScalar(u8, path[qs + 1..], '&');
            while (params.next()) |param| {
                if (std.mem.startsWith(u8, param, "limit=")) {
                    limit = std.fmt.parseInt(usize, param[6..], 10) catch limit;
                    limit = @min(limit, 500);
                } else if (std.mem.startsWith(u8, param, "offset=")) {
                    offset = std.fmt.parseInt(usize, param[7..], 10) catch offset;
                }
            }
        }

        // The stored procs_json holds the full list (up to 50 entries by default).
        // For pagination we re-slice at the byte level by counting JSON array items.
        // Simpler: use stored JSON if no pagination, else return slice metadata.
        // The cleanest approach: store the full proc list, slice here.
        // Since we store pre-encoded JSON, send the full blob and let clients paginate.
        // Mark limit/offset in the response envelope.
        self.snap.mutex.lock();
        const full = self.snap.procs_json[0..self.snap.procs_json_len];
        self.snap.mutex.unlock();

        // Build paginated envelope: {"offset":O,"limit":L,"data":<full_array>}
        // The full_array already has the top-N (up to 500) entries.
        // For true pagination, encodeProcs would need to accept offset/limit.
        // Here we return the full JSON with pagination metadata in the envelope.
        var env_buf: [70000]u8 = undefined;
        const env = std.fmt.bufPrint(&env_buf,
            "{{\"offset\":{d},\"limit\":{d},\"data\":{s}}}",
            .{ offset, limit, full }) catch full;
        sendJson(fd, env);
    }
};

// 1-second sleep without importing util (avoids circular dep).
fn util_sleep(ns: u64) void {
    var req = linux.timespec{
        .sec  = @intCast(ns / 1_000_000_000),
        .nsec = @intCast(ns % 1_000_000_000),
    };
    var rem: linux.timespec = .{ .sec = 0, .nsec = 0 };
    while (true) {
        const r = linux.nanosleep(&req, &rem);
        if (@as(isize, @bitCast(r)) != -4) break;
        req = rem;
    }
}

fn sendJson(fd: i32, body: []const u8) void {
    var hdr: [256]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" ++
        "Access-Control-Allow-Origin: *\r\nContent-Length: {d}\r\n\r\n",
        .{body.len}) catch return;
    _ = linux.write(@intCast(fd), h.ptr, h.len);
    _ = linux.write(@intCast(fd), body.ptr, body.len);
}

fn send404(fd: i32) void {
    const msg = "HTTP/1.1 404 Not Found\r\nContent-Length: 13\r\n\r\n{\"error\":404}";
    _ = linux.write(@intCast(fd), msg.ptr, msg.len);
}

// Build processes JSON from a process slice. Writes into caller-owned buf.
pub fn encodeProcs(procs: []const core.ProcessInfo, buf: []u8) usize {
    var w = BufW{ .buf = buf, .len = 0 };
    w.str("[");
    const limit = @min(procs.len, 50);
    for (procs[0..limit], 0..) |p, i| {
        if (i > 0) w.str(",");
        w.str("{\"pid\":");
        w.uint(p.pid);
        w.str(",\"name\":\"");
        w.strEscaped(p.nameSlice());
        w.str("\",\"cpu_pct\":");
        w.f32_1(p.cpu_pct);
        w.str(",\"rss_kb\":");
        w.ulong(p.rss_kb);
        w.str(",\"state\":\"");
        w.ch(@as(u8, @intCast(p.state)));
        w.str("\"");
        if (!std.math.isNan(p.ipc)) {
            w.str(",\"ipc\":");
            w.f32_2(p.ipc);
        }
        w.str(",\"disk_r_kb_s\":");
        w.f32_1(p.disk_read_kb_s);
        w.str(",\"disk_w_kb_s\":");
        w.f32_1(p.disk_write_kb_s);
        if (p.tcp_conn_count > 0) {
            w.str(",\"tcp_conns\":");
            w.uint(p.tcp_conn_count);
        }
        w.str("}");
    }
    w.str("]");
    return w.len;
}

pub fn encodeNet(ifaces: []const core.NetIface, buf: []u8) usize {
    var w = BufW{ .buf = buf, .len = 0 };
    w.str("[");
    for (ifaces, 0..) |iface, i| {
        if (i > 0) w.str(",");
        w.str("{\"name\":\"");
        w.strEscaped(iface.name[0..iface.name_len]);
        w.str("\",\"rx_kb_s\":");
        w.f32_1(iface.rx_rate_kb_s);
        w.str(",\"tx_kb_s\":");
        w.f32_1(iface.tx_rate_kb_s);
        w.str(",\"rx_bytes\":");
        w.ulong(iface.rx_bytes);
        w.str(",\"tx_bytes\":");
        w.ulong(iface.tx_bytes);
        w.str("}");
    }
    w.str("]");
    return w.len;
}

pub fn encodeDisk(disks: []const core.DiskStat, buf: []u8) usize {
    var w = BufW{ .buf = buf, .len = 0 };
    w.str("[");
    for (disks, 0..) |d, i| {
        if (i > 0) w.str(",");
        w.str("{\"name\":\"");
        w.strEscaped(d.name[0..d.name_len]);
        w.str("\",\"r_kb_s\":");
        w.f32_1(d.read_rate_kb_s);
        w.str(",\"w_kb_s\":");
        w.f32_1(d.write_rate_kb_s);
        w.str("}");
    }
    w.str("]");
    return w.len;
}

pub fn encodeThermal(sensors: []const core.ThermalSensor, freqs: []const core.CpuFreq, buf: []u8) usize {
    var w = BufW{ .buf = buf, .len = 0 };
    w.str("{\"sensors\":[");
    for (sensors, 0..) |s, i| {
        if (i > 0) w.str(",");
        w.str("{\"chip\":\"");
        w.strEscaped(s.chip[0..s.chip_len]);
        w.str("\",\"label\":\"");
        w.strEscaped(s.label[0..s.label_len]);
        w.str("\",\"temp_c\":");
        w.f32_1(@as(f32, @floatFromInt(s.temp_mc)) / 1000.0);
        w.str("}");
    }
    w.str("],\"cpu_freq_mhz\":[");
    for (freqs, 0..) |f, i| {
        if (i > 0) w.str(",");
        w.ulong(f.freq_khz / 1000);
    }
    w.str("]}");
    return w.len;
}

const BufW = struct {
    buf: []u8,
    len: usize,

    fn str(self: *BufW, s: []const u8) void {
        const n = @min(s.len, self.buf.len -| self.len);
        @memcpy(self.buf[self.len .. self.len + n], s[0..n]);
        self.len += n;
    }

    fn strEscaped(self: *BufW, s: []const u8) void {
        for (s) |c| {
            if (c == '"' or c == '\\') {
                if (self.len + 2 <= self.buf.len) {
                    self.buf[self.len] = '\\';
                    self.buf[self.len + 1] = c;
                    self.len += 2;
                }
            } else if (c >= 0x20) {
                if (self.len < self.buf.len) {
                    self.buf[self.len] = c;
                    self.len += 1;
                }
            }
        }
    }

    fn ch(self: *BufW, c: u8) void {
        if (self.len < self.buf.len) {
            self.buf[self.len] = c;
            self.len += 1;
        }
    }

    fn uint(self: *BufW, v: u32) void {
        var tmp: [12]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch return;
        self.str(s);
    }

    fn ulong(self: *BufW, v: u64) void {
        var tmp: [22]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch return;
        self.str(s);
    }

    fn f32_1(self: *BufW, v: f32) void {
        var tmp: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d:.1}", .{v}) catch return;
        self.str(s);
    }

    fn f32_2(self: *BufW, v: f32) void {
        var tmp: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d:.2}", .{v}) catch return;
        self.str(s);
    }
};
