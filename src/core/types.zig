//! Core snapshot types for ZTOP.
//!
//! Struct-of-Arrays layout for process table — sort index arrays, not structs.
//! All timestamps are nanoseconds since epoch (std.time.nanoTimestamp()).

const std = @import("std");

// ── CPU ──────────────────────────────────────────────────────────────────────

/// Raw /proc/stat fields for one CPU (aggregate or per-core).
pub const CpuTick = struct {
    user: u64 = 0,
    nice: u64 = 0,
    system: u64 = 0,
    idle: u64 = 0,
    iowait: u64 = 0,
    irq: u64 = 0,
    softirq: u64 = 0,
    steal: u64 = 0,

    pub fn total(self: CpuTick) u64 {
        return self.user + self.nice + self.system + self.idle +
            self.iowait + self.irq + self.softirq + self.steal;
    }

    pub fn active(self: CpuTick) u64 {
        return self.total() - self.idle - self.iowait;
    }

    pub fn pct(prev: CpuTick, curr: CpuTick) f32 {
        const dtotal = @as(f64, @floatFromInt(curr.total() -| prev.total()));
        const dactive = @as(f64, @floatFromInt(curr.active() -| prev.active()));
        if (dtotal == 0) return 0.0;
        return @floatCast(dactive * 100.0 / dtotal);
    }
};

/// One complete CPU telemetry snapshot (all cores + aggregate + memory).
pub const CpuSnapshot = struct {
    timestamp_ns: i64,

    // Per-core ticks (len = nproc)
    cores: []CpuTick,
    total: CpuTick,

    // Derived (caller fills after delta with previous snapshot)
    core_pct: []f32,
    total_pct: f32,

    // Memory (KB)
    mem_total_kb: u64,
    mem_free_kb: u64,
    mem_available_kb: u64,
    mem_cached_kb: u64,
    mem_buffers_kb: u64,
    swap_total_kb: u64,
    swap_free_kb: u64,

    // System
    load_1: f32,
    load_5: f32,
    load_15: f32,
    uptime_s: u64,

    pub fn mem_used_kb(self: CpuSnapshot) u64 {
        return self.mem_total_kb -| self.mem_available_kb;
    }

    pub fn swap_used_kb(self: CpuSnapshot) u64 {
        return self.swap_total_kb -| self.swap_free_kb;
    }
};

// ── Process ───────────────────────────────────────────────────────────────────

/// Per-process snapshot. Micro-arch fields are populated only when
/// perf_event_open succeeds (requires paranoid ≤ 1 or CAP_PERFMON/root).
pub const ProcessInfo = struct {
    pid: u32,
    ppid: u32,
    name: [64]u8,
    name_len: u8,
    state: u8, // 'R','S','D','Z','T'

    // CPU
    utime: u64,  // jiffies
    stime: u64,
    cpu_pct: f32, // derived

    // Memory
    vsize_kb: u64,
    rss_kb: u64,

    // Micro-architectural (perf_event_open; NaN = unavailable)
    ipc: f32,               // instructions / cycle — nobody else shows this
    l1_miss_rate: f32,      // L1 cache misses / instructions
    l3_miss_rate: f32,      // LLC cache misses / instructions
    branch_miss_rate: f32,  // branch mispredictions / instructions

    // Disk I/O rates (from /proc/PID/io deltas)
    disk_read_kb_s: f32 = 0,
    disk_write_kb_s: f32 = 0,

    // Container label (first 12 chars of cgroup docker ID, empty if bare metal)
    container_id: [13]u8 = [_]u8{0} ** 13,
    container_id_len: u8 = 0,

    pub fn nameSlice(self: *const ProcessInfo) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn containerSlice(self: *const ProcessInfo) []const u8 {
        return self.container_id[0..self.container_id_len];
    }
};

// ── Network ───────────────────────────────────────────────────────────────────

pub const NetIface = struct {
    name: [16]u8,
    name_len: u8,
    rx_bytes: u64,
    tx_bytes: u64,
    rx_packets: u64,
    tx_packets: u64,
    rx_errors: u64,
    tx_errors: u64,
    rx_rate_kb_s: f32,
    tx_rate_kb_s: f32,

    pub fn nameSlice(self: *const NetIface) []const u8 {
        return self.name[0..self.name_len];
    }
};

// ── Disk ──────────────────────────────────────────────────────────────────────

pub const DiskStat = struct {
    name: [16]u8,
    name_len: u8,
    reads_completed: u64,
    writes_completed: u64,
    read_bytes: u64,
    write_bytes: u64,
    read_rate_kb_s: f32,
    write_rate_kb_s: f32,

    pub fn nameSlice(self: *const DiskStat) []const u8 {
        return self.name[0..self.name_len];
    }
};

// ── Thermal ───────────────────────────────────────────────────────────────────

pub const ThermalSensor = struct {
    chip: [32]u8,
    chip_len: u8,
    label: [32]u8,
    label_len: u8,
    temp_mc: u64, // millidegrees Celsius

    pub fn temp_c(self: ThermalSensor) f32 {
        return @as(f32, @floatFromInt(self.temp_mc)) / 1000.0;
    }

    pub fn chipSlice(self: *const ThermalSensor) []const u8 {
        return self.chip[0..self.chip_len];
    }

    pub fn labelSlice(self: *const ThermalSensor) []const u8 {
        return self.label[0..self.label_len];
    }
};

pub const CpuFreq = struct {
    core_id: u32,
    freq_khz: u64,

    pub fn freq_mhz(self: CpuFreq) f32 {
        return @as(f32, @floatFromInt(self.freq_khz)) / 1000.0;
    }
};

pub const PowerInfo = struct {
    package_w: f32,
    core_w: f32,
    dram_w: f32,
    valid: bool, // false if RAPL not available
};

// ── GPU ───────────────────────────────────────────────────────────────────────

pub const GpuInfo = struct {
    index: u32,
    name: [96]u8,
    name_len: u8,

    // Utilization (%)
    util_gpu: u32,
    util_mem_ctrl: u32,

    // Memory (MiB)
    vram_used_mib: u64,
    vram_total_mib: u64,

    // Thermal + power
    temp_c: u32,
    power_mw: u32,
    power_limit_mw: u32,

    // Clocks (MHz)
    sm_clock_mhz: u32,
    mem_clock_mhz: u32,
    gr_clock_mhz: u32,

    // PCIe bandwidth (KiB/s)
    pcie_tx_kb: u64,
    pcie_rx_kb: u64,

    // Per-process VRAM (for OOM velocity tracking)
    processes: []GpuProcessInfo,

    pub fn vram_pct(self: GpuInfo) f32 {
        if (self.vram_total_mib == 0) return 0.0;
        return @as(f32, @floatFromInt(self.vram_used_mib)) * 100.0 /
            @as(f32, @floatFromInt(self.vram_total_mib));
    }

    pub fn power_pct(self: GpuInfo) f32 {
        if (self.power_limit_mw == 0) return 0.0;
        return @as(f32, @floatFromInt(self.power_mw)) * 100.0 /
            @as(f32, @floatFromInt(self.power_limit_mw));
    }

    pub fn nameSlice(self: *const GpuInfo) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const GpuProcessInfo = struct {
    pid: u32,
    vram_used_mib: u64,
    vram_velocity_mib_s: f32, // rate of change — OOM predictor
};

// ── History ───────────────────────────────────────────────────────────────────

/// Ring buffer of CPU snapshots for temporal rewind.
/// Fixed capacity; oldest entry is overwritten when full.
pub const HistoryBuf = struct {
    const CAP = 1800; // 30 min at 1Hz, or 3 min at 10Hz

    timestamps: [CAP]i64,
    total_pct: [CAP]f32,
    mem_used_pct: [CAP]f32,
    write: usize,
    count: usize,

    pub fn init() HistoryBuf {
        return .{
            .timestamps = [_]i64{0} ** CAP,
            .total_pct = [_]f32{0} ** CAP,
            .mem_used_pct = [_]f32{0} ** CAP,
            .write = 0,
            .count = 0,
        };
    }

    pub fn push(self: *HistoryBuf, snap: CpuSnapshot) void {
        const i = self.write % CAP;
        self.timestamps[i] = snap.timestamp_ns;
        self.total_pct[i] = snap.total_pct;
        const mem_pct: f32 = if (snap.mem_total_kb == 0) 0.0
            else @as(f32, @floatFromInt(snap.mem_used_kb())) * 100.0 /
                 @as(f32, @floatFromInt(snap.mem_total_kb));
        self.mem_used_pct[i] = mem_pct;
        self.write += 1;
        if (self.count < CAP) self.count += 1;
    }

    /// Returns the last `n` CPU% samples in chronological order.
    pub fn lastN(self: *const HistoryBuf, n: usize, out: []f32) usize {
        const take = @min(n, self.count);
        if (take == 0) return 0;
        const start = (self.write + CAP - take) % CAP;
        for (0..take) |i| {
            out[i] = self.total_pct[(start + i) % CAP];
        }
        return take;
    }

    /// Binary search: find snapshot with timestamp <= target_ns.
    pub fn asof(self: *const HistoryBuf, target_ns: i64) ?f32 {
        if (self.count == 0) return null;
        const start = (self.write + CAP - self.count) % CAP;
        var lo: usize = 0;
        var hi: usize = self.count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.timestamps[(start + mid) % CAP] <= target_ns) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if (lo == 0) return null;
        return self.total_pct[(start + lo - 1) % CAP];
    }
};

test "HistoryBuf push + lastN + asof" {
    var h = HistoryBuf.init();
    var snap = CpuSnapshot{
        .timestamp_ns = 1_000_000_000,
        .cores = &.{},
        .total = .{},
        .core_pct = &.{},
        .total_pct = 25.0,
        .mem_total_kb = 16_000_000,
        .mem_free_kb = 8_000_000,
        .mem_available_kb = 8_000_000,
        .mem_cached_kb = 0,
        .mem_buffers_kb = 0,
        .swap_total_kb = 0,
        .swap_free_kb = 0,
        .load_1 = 0.5,
        .load_5 = 0.4,
        .load_15 = 0.3,
        .uptime_s = 3600,
    };
    h.push(snap);
    snap.timestamp_ns = 2_000_000_000;
    snap.total_pct = 50.0;
    h.push(snap);
    snap.timestamp_ns = 3_000_000_000;
    snap.total_pct = 75.0;
    h.push(snap);

    var out: [10]f32 = undefined;
    const n = h.lastN(3, &out);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectApproxEqAbs(@as(f32, 25.0), out[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 75.0), out[2], 0.01);

    // asof: "what was CPU% at ts=1.5s?" → first entry (ts=1s)
    const pct = h.asof(1_500_000_000);
    try std.testing.expect(pct != null);
    try std.testing.expectApproxEqAbs(@as(f32, 25.0), pct.?, 0.01);
}
