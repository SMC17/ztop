//! GPU telemetry collector via NVML.
//!
//! Threading model: NVML calls run on a dedicated thread (GpuPoller) and
//! write into an atomic double-buffer. The UI thread reads the snapshot with
//! zero lock contention and guaranteed non-stale data.
//!
//! NVML init → enumerate devices → spawn GpuPoller thread → poll loop.
//! On shutdown: set running=false, join thread, nvmlShutdown().
//!
//! Degrades gracefully: if nvmlInit fails (no GPU, no driver), GpuPoller
//! returns empty snapshot list and the UI shows "GPU: not available".

const std = @import("std");
const core = @import("core");
const util = @import("util");
const c = @cImport(@cInclude("nvml_stub.h"));

pub const MAX_DEVICES = 8;
const MAX_PROCS_PER_GPU = 64;
const POLL_INTERVAL_NS = 200_000_000; // 200ms — GPU metrics change slowly

// ── Atomic double-buffer ──────────────────────────────────────────────────────

/// One complete GPU snapshot for all devices.
pub const GpuFrame = struct {
    device_count: u32,
    devices: [MAX_DEVICES]core.GpuInfo,
    proc_buf: [MAX_DEVICES][MAX_PROCS_PER_GPU]core.GpuProcessInfo,
    timestamp_ns: i64,
};

var frame_a: GpuFrame = std.mem.zeroes(GpuFrame);
var frame_b: GpuFrame = std.mem.zeroes(GpuFrame);
var active: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);

/// Read the latest GPU snapshot. Always returns a consistent frame
/// (the one not currently being written to).
pub fn readLatest() *const GpuFrame {
    return if (active.load(.acquire) == 0) &frame_a else &frame_b;
}

// ── NVML helpers ─────────────────────────────────────────────────────────────

fn nvmlOk(r: c.nvmlReturn_t) bool {
    return r == c.NVML_SUCCESS;
}

fn pollDevice(device: c.nvmlDevice_t, index: u32, frame: *GpuFrame) void {
    var info = &frame.devices[index];
    info.index = index;

    // Name
    var name_buf: [c.NVML_DEVICE_NAME_BUFFER_SIZE]u8 = undefined;
    if (nvmlOk(c.nvmlDeviceGetName(device, &name_buf, c.NVML_DEVICE_NAME_BUFFER_SIZE))) {
        const name = std.mem.sliceTo(&name_buf, 0);
        const n = @min(name.len, info.name.len - 1);
        @memcpy(info.name[0..n], name[0..n]);
        info.name_len = @intCast(n);
    }

    // Utilization
    var nvml_util: c.nvmlUtilization_t = .{ .gpu = 0, .memory = 0 };
    if (nvmlOk(c.nvmlDeviceGetUtilizationRates(device, &nvml_util))) {
        info.util_gpu = nvml_util.gpu;
        info.util_mem_ctrl = nvml_util.memory;
    }

    // Memory
    var mem: c.nvmlMemory_t = .{ .total = 0, .free = 0, .used = 0 };
    if (nvmlOk(c.nvmlDeviceGetMemoryInfo(device, &mem))) {
        info.vram_total_mib = mem.total / (1024 * 1024);
        info.vram_used_mib  = mem.used  / (1024 * 1024);
    }

    // Temperature
    var temp: c_uint = 0;
    if (nvmlOk(c.nvmlDeviceGetTemperature(device, c.NVML_TEMPERATURE_GPU, &temp))) {
        info.temp_c = temp;
    }

    // Power
    var power: c_uint = 0;
    if (nvmlOk(c.nvmlDeviceGetPowerUsage(device, &power))) info.power_mw = power;
    var limit: c_uint = 0;
    if (nvmlOk(c.nvmlDeviceGetEnforcedPowerLimit(device, &limit))) info.power_limit_mw = limit;

    // Clocks
    var clk: c_uint = 0;
    if (nvmlOk(c.nvmlDeviceGetClockInfo(device, c.NVML_CLOCK_SM, &clk))) info.sm_clock_mhz = clk;
    if (nvmlOk(c.nvmlDeviceGetClockInfo(device, c.NVML_CLOCK_MEM, &clk))) info.mem_clock_mhz = clk;
    if (nvmlOk(c.nvmlDeviceGetClockInfo(device, c.NVML_CLOCK_GRAPHICS, &clk))) info.gr_clock_mhz = clk;

    // PCIe bandwidth
    var pcie: c_uint = 0;
    if (nvmlOk(c.nvmlDeviceGetPcieThroughput(device, c.NVML_PCIE_UTIL_TX_BYTES, &pcie)))
        info.pcie_tx_kb = pcie;
    if (nvmlOk(c.nvmlDeviceGetPcieThroughput(device, c.NVML_PCIE_UTIL_RX_BYTES, &pcie)))
        info.pcie_rx_kb = pcie;

    // Per-process VRAM (OOM predictor feed)
    var proc_infos: [MAX_PROCS_PER_GPU]c.nvmlProcessInfo_t = undefined;
    var proc_count: c_uint = MAX_PROCS_PER_GPU;
    if (nvmlOk(c.nvmlDeviceGetComputeRunningProcesses(device, &proc_count, &proc_infos))) {
        const n = @min(@as(usize, proc_count), MAX_PROCS_PER_GPU);
        for (proc_infos[0..n], 0..) |p, i| {
            frame.proc_buf[index][i] = .{
                .pid = p.pid,
                .vram_used_mib = if (p.usedGpuMemory == c.NVML_VALUE_NOT_AVAILABLE) 0
                    else p.usedGpuMemory / (1024 * 1024),
                .vram_velocity_mib_s = 0.0, // computed below by GpuPoller
            };
        }
        // Wire slice into info
        info.processes = frame.proc_buf[index][0..n];
    } else {
        info.processes = frame.proc_buf[index][0..0];
    }
}

// ── GpuPoller thread ──────────────────────────────────────────────────────────

const PrevVramEntry = struct { pid: u32, mib: u64 };

var running = std.atomic.Value(bool).init(false);

pub const GpuPoller = struct {
    thread: std.Thread,
    device_count: u32,
    devices: [MAX_DEVICES]c.nvmlDevice_t,
    prev_vram: [MAX_DEVICES][MAX_PROCS_PER_GPU]PrevVramEntry,
    available: bool,

    pub fn start(alloc: std.mem.Allocator) !GpuPoller {
        _ = alloc;
        var p: GpuPoller = .{
            .thread = undefined,
            .device_count = 0,
            .devices = undefined,
            .prev_vram = std.mem.zeroes([MAX_DEVICES][MAX_PROCS_PER_GPU]PrevVramEntry),
            .available = false,
        };

        // Try to init NVML
        if (!nvmlOk(c.nvmlInit_v2())) {
            // No GPU / no driver — degrade silently
            return p;
        }

        var count: c_uint = 0;
        if (!nvmlOk(c.nvmlDeviceGetCount_v2(&count)) or count == 0) {
            _ = c.nvmlShutdown();
            return p;
        }

        p.device_count = @min(count, MAX_DEVICES);
        for (0..p.device_count) |i| {
            _ = c.nvmlDeviceGetHandleByIndex_v2(@intCast(i), &p.devices[i]);
        }

        p.available = true;
        running.store(true, .release);
        p.thread = try std.Thread.spawn(.{}, gpuPollerLoop, .{&p});
        return p;
    }

    pub fn stop(self: *GpuPoller) void {
        if (!self.available) return;
        running.store(false, .release);
        self.thread.join();
        _ = c.nvmlShutdown();
    }
};

fn gpuPollerLoop(p: *GpuPoller) void {
    while (running.load(.acquire)) {
        // Write to the inactive buffer
        const write_to: *GpuFrame = if (active.load(.acquire) == 0) &frame_b else &frame_a;
        write_to.device_count = p.device_count;
        write_to.timestamp_ns = util.nanoTimestamp();

        for (0..p.device_count) |i| {
            pollDevice(p.devices[i], @intCast(i), write_to);

            // Compute VRAM velocity per process
            for (write_to.devices[i].processes, 0..) |*proc, j| {
                // Find previous measurement for same pid
                var prev_mib: u64 = proc.vram_used_mib;
                for (p.prev_vram[i]) |prev| {
                    if (prev.pid == proc.pid) { prev_mib = prev.mib; break; }
                }
                const delta = @as(f32, @floatFromInt(proc.vram_used_mib)) -
                              @as(f32, @floatFromInt(prev_mib));
                proc.vram_velocity_mib_s = delta * (1_000_000_000.0 / @as(f32, POLL_INTERVAL_NS));
                p.prev_vram[i][j] = PrevVramEntry{ .pid = proc.pid, .mib = proc.vram_used_mib };
            }
        }

        // Atomic flip
        _ = active.fetchXor(1, .release);
        util.sleep(POLL_INTERVAL_NS);
    }
}
