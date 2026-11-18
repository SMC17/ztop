# ztop

Zig-native system monitor. Two binaries:

- **`ztop`** — htop successor: CPU utilization, memory, per-process table with IPC column (instructions-per-cycle via `perf_event_open`), temporal rewind backed by a ring-buffer time-series engine.
- **`ztop-g`** — nvtop successor: NVIDIA GPU monitor with per-PID VRAM allocation velocity for OOM prediction.

## What makes it different

Every other system monitor (htop, btop, bottom, nvtop) shows you a snapshot. ztop adds:

1. **IPC column** — `perf_event_open` reports instructions-per-cycle per process. A process with IPC=0.3 is memory-bound; IPC=4.0 is compute-bound. No other standard monitor shows this.

2. **Temporal rewind** — Press `r` + left/right arrow to rewind CPU history. Powered by `HistoryBuf.asof()`: binary search on a monotone ring buffer. Hit a spike 2 minutes ago? Rewind to it.

3. **Per-PID VRAM velocity** — ztop-g tracks VRAM rate-of-change per process in MiB/s. A process growing at +200 MiB/s will OOM in N seconds — shown live.

4. **Zero allocation in render path** — arena-per-tick frame loop; GPU poller on isolated thread with atomic double-buffer; single `write(2)` call per frame.

## Build

Requires: Zig 0.16, NVIDIA driver (for ztop-g), Linux.

```
zig build                    # builds ztop (and ztop-g on Linux) into zig-out/bin/
zig build run                # run ztop (CPU monitor)
zig build run-gpu            # run ztop-g (GPU monitor)
zig build test --summary all # run tests
```

Dependencies: [zkdb](https://github.com/SMC17/zkdb) (pinned git dependency in `build.zig.zon`, fetched by `zig build`).

On non-Linux hosts `zig build test` skips the two smoke tests that read the live `/proc` filesystem.

### perf_event_open permissions

IPC collection requires `perf_event_paranoid` ≤ 1, or `CAP_PERFMON`, or running as root.

```
# Temporary (lost on reboot):
echo 1 | sudo tee /proc/sys/kernel/perf_event_paranoid

# Permanent:
echo 'kernel.perf_event_paranoid = 1' | sudo tee /etc/sysctl.d/99-perf.conf
```

When unavailable, the IPC column shows `N/A` — ztop degrades gracefully.

## Architecture

```
ztop                           ztop-g
│                              │
├─ arena-per-tick loop         ├─ GpuPoller thread (200ms)
│  ├─ Collector.collect()      │   ├─ NVML poll all devices
│  │   ├─ /proc/stat           │   ├─ per-PID VRAM + velocity
│  │   ├─ /proc/meminfo        │   └─ atomic double-buffer flip
│  │   └─ /proc/[pid]/stat     │
│  ├─ HistoryBuf.push()        ├─ render loop (500ms)
│  ├─ collectProcesses()       │   ├─ readLatest() [zero-copy]
│  └─ renderFrame()            │   └─ ansi.Screen.flush()
│      └─ ansi.Screen.flush()
│
HistoryBuf (ring buffer, 1800 slots)
└─ asof(target_ns) — binary search for temporal rewind
```

## Status

v0.0.1 — functional scaffold. Tests pass. Both binaries build and run.

Roadmap:
- [ ] Accurate per-process CPU% via actual elapsed time (not jiffies heuristic)
- [ ] `perf_event_open` per-PID (currently self-process only; cross-process needs paranoid ≤ 1)
- [ ] Mouse support (click to select process)
- [ ] `--record` mode: persist ring buffer to zkdb column files for offline analysis
- [ ] `--replay` mode: replay a recorded session
- [ ] L1/L3 cache miss rate + branch miss rate columns (counters already wired)
- [ ] Tensor Core utilization (NVML `nvmlDeviceGetMPSComputeRunningProcesses`)
- [ ] ETF binary format IPC wire protocol for fleet-level aggregation
