// Thermal + frequency collector for ztop.
//
// Data sources:
//   /sys/class/hwmon/hwmon*/temp*_input  — temperatures in millidegrees C
//   /sys/class/hwmon/hwmon*/name         — chip name (coretemp, k10temp, etc.)
//   /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq — current freq in kHz
//   /sys/class/powercap/intel-rapl:*/energy_uj — Intel RAPL power (microjoules)
//
// This beats glances (more depth), btop (same data, but we expose raw values),
// and is unique in combining temps + freq + power in one struct.

const std = @import("std");
const core = @import("core");
const linux = std.os.linux;
const posix = std.posix;

fn readU64Z(path: [*:0]const u8) ?u64 {
    const fd = posix.openatZ(posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer _ = linux.close(@intCast(fd));
    var buf: [32]u8 = undefined;
    const n = posix.read(fd, &buf) catch return null;
    const s = std.mem.trim(u8, buf[0..n], " \t\n\r");
    return std.fmt.parseInt(u64, s, 10) catch null;
}

fn readStrZ(path: [*:0]const u8, out: []u8) usize {
    const fd = posix.openatZ(posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return 0;
    defer _ = linux.close(@intCast(fd));
    const n = posix.read(fd, out) catch return 0;
    const s = std.mem.trim(u8, out[0..n], " \t\n\r");
    return s.len;
}

// Scan /sys/class/hwmon for temperature sensors.
pub fn collectThermal(alloc: std.mem.Allocator) ![]core.ThermalSensor {
    var sensors: std.ArrayListUnmanaged(core.ThermalSensor) = .empty;
    errdefer sensors.deinit(alloc);

    const dfd = posix.openatZ(posix.AT.FDCWD, "/sys/class/hwmon",
        .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0) catch return &.{};
    defer _ = linux.close(@intCast(dfd));

    const Dirent = extern struct {
        d_ino: u64, d_off: i64, d_reclen: u16, d_type: u8,
    };

    var dbuf: [4096]u8 align(8) = undefined;
    while (true) {
        const n: isize = @bitCast(linux.getdents64(@intCast(dfd), &dbuf, dbuf.len));
        if (n <= 0) break;
        var off: usize = 0;
        while (off < @as(usize, @intCast(n))) {
            const ent: *const Dirent = @ptrCast(@alignCast(&dbuf[off]));
            off += ent.d_reclen;
            const name_ptr: [*:0]const u8 = @ptrCast(&dbuf[off - ent.d_reclen + @sizeOf(Dirent)]);
            const hwmon_name = std.mem.sliceTo(name_ptr, 0);
            if (!std.mem.startsWith(u8, hwmon_name, "hwmon")) continue;

            // Read chip name.
            var chip_name_buf: [32]u8 = undefined;
            var name_path: [128]u8 = undefined;
            const np_s = std.fmt.bufPrintZ(&name_path,
                "/sys/class/hwmon/{s}/name", .{hwmon_name}) catch continue;
            const chip_len = readStrZ(name_path[0..np_s.len :0], &chip_name_buf);

            // Scan temp*_input files.
            var temp_idx: u32 = 1;
            while (temp_idx <= 32) : (temp_idx += 1) {
                var temp_path: [128]u8 = undefined;
                const tp = std.fmt.bufPrintZ(&temp_path,
                    "/sys/class/hwmon/{s}/temp{d}_input",
                    .{ hwmon_name, temp_idx }) catch break;
                const millic = readU64Z(temp_path[0..tp.len :0]) orelse break;

                // Read label if available.
                var label_path: [128]u8 = undefined;
                const lp = std.fmt.bufPrintZ(&label_path,
                    "/sys/class/hwmon/{s}/temp{d}_label",
                    .{ hwmon_name, temp_idx }) catch continue;
                var label_buf: [32]u8 = undefined;
                const label_len = readStrZ(label_path[0..lp.len :0], &label_buf);

                var sensor = core.ThermalSensor{
                    .chip = [_]u8{0} ** 32,
                    .chip_len = @intCast(@min(chip_len, 31)),
                    .label = [_]u8{0} ** 32,
                    .label_len = @intCast(@min(label_len, 31)),
                    .temp_mc = millic,
                };
                if (chip_len > 0) @memcpy(sensor.chip[0..sensor.chip_len], chip_name_buf[0..sensor.chip_len]);
                if (label_len > 0) @memcpy(sensor.label[0..sensor.label_len], label_buf[0..sensor.label_len]);
                try sensors.append(alloc, sensor);
            }
        }
    }
    return sensors.toOwnedSlice(alloc);
}

// Read per-core CPU frequencies from cpufreq.
pub fn collectCpuFreqs(alloc: std.mem.Allocator) ![]core.CpuFreq {
    var freqs: std.ArrayListUnmanaged(core.CpuFreq) = .empty;
    errdefer freqs.deinit(alloc);

    var core_idx: u32 = 0;
    while (core_idx < 512) : (core_idx += 1) {
        var freq_path: [128]u8 = undefined;
        const fp = std.fmt.bufPrintZ(&freq_path,
            "/sys/devices/system/cpu/cpu{d}/cpufreq/scaling_cur_freq",
            .{core_idx}) catch break;
        const khz = readU64Z(freq_path[0..fp.len :0]) orelse break;
        try freqs.append(alloc, .{ .core_id = core_idx, .freq_khz = khz });
    }
    return freqs.toOwnedSlice(alloc);
}

// Read Intel RAPL power (microjoules, cumulative). Caller computes delta.
pub const RaplReading = struct {
    package_uj: u64,
    core_uj: u64,
    dram_uj: u64,
};

pub fn readRapl() RaplReading {
    var r: RaplReading = .{ .package_uj = 0, .core_uj = 0, .dram_uj = 0 };

    var path: [128]u8 = undefined;
    const pkg_path = std.fmt.bufPrintZ(&path,
        "/sys/class/powercap/intel-rapl:0/energy_uj", .{}) catch return r;
    r.package_uj = readU64Z(path[0..pkg_path.len :0]) orelse 0;

    const core_path = std.fmt.bufPrintZ(&path,
        "/sys/class/powercap/intel-rapl:0:0/energy_uj", .{}) catch return r;
    r.core_uj = readU64Z(path[0..core_path.len :0]) orelse 0;

    const dram_path = std.fmt.bufPrintZ(&path,
        "/sys/class/powercap/intel-rapl:0:2/energy_uj", .{}) catch return r;
    r.dram_uj = readU64Z(path[0..dram_path.len :0]) orelse 0;

    return r;
}

// Stateful RAPL collector computing watts from cumulative microjoule deltas.
pub const PowerCollector = struct {
    prev: RaplReading,
    prev_ts_ns: i64,

    pub fn init(ts_ns: i64) PowerCollector {
        return .{ .prev = readRapl(), .prev_ts_ns = ts_ns };
    }

    pub fn sample(self: *PowerCollector, ts_ns: i64) core.PowerInfo {
        const curr = readRapl();
        const dt_s = @as(f32, @floatFromInt(ts_ns - self.prev_ts_ns)) / 1e9;

        var pi = core.PowerInfo{ .package_w = 0, .core_w = 0, .dram_w = 0, .valid = false };
        if (dt_s > 0 and self.prev.package_uj > 0) {
            pi.package_w = @as(f32, @floatFromInt(curr.package_uj -| self.prev.package_uj)) / (dt_s * 1e6);
            pi.core_w    = @as(f32, @floatFromInt(curr.core_uj    -| self.prev.core_uj))    / (dt_s * 1e6);
            pi.dram_w    = @as(f32, @floatFromInt(curr.dram_uj    -| self.prev.dram_uj))    / (dt_s * 1e6);
            pi.valid = true;
        }
        self.prev = curr;
        self.prev_ts_ns = ts_ns;
        return pi;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "collectCpuFreqs smoke" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const freqs = try collectCpuFreqs(arena.allocator());
    // May be empty in a VM/container without cpufreq, that's OK.
    for (freqs) |f| {
        try std.testing.expect(f.freq_khz > 0);
    }
}

test "collectThermal smoke" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sensors = try collectThermal(arena.allocator());
    for (sensors) |s| {
        try std.testing.expect(s.temp_mc > 0);
    }
}
