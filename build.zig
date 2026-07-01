const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zkdb_dep = b.dependency("zkdb", .{ .target = target });
    const zkdb_mod = zkdb_dep.module("zkdb");

    // Shared util module (time, sleep via linux syscalls)
    const util_mod = b.createModule(.{
        .root_source_file = b.path("src/util.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Shared core module
    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/core/types.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_mod.addImport("zkdb", zkdb_mod);
    core_mod.addImport("util", util_mod);

    // CPU collector module
    const cpu_col_mod = b.createModule(.{
        .root_source_file = b.path("src/collector/cpu/linux.zig"),
        .target = target,
        .optimize = optimize,
    });
    cpu_col_mod.addImport("core", core_mod);
    cpu_col_mod.addImport("util", util_mod);

    // ztop — CPU system monitor
    const ztop = b.addExecutable(.{
        .name = "ztop",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_cpu.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zkdb", .module = zkdb_mod },
                .{ .name = "core", .module = core_mod },
                .{ .name = "cpu", .module = cpu_col_mod },
                .{ .name = "util", .module = util_mod },
            },
        }),
    });
    b.installArtifact(ztop);

    // ztop-g — GPU monitor
    const gpu_col_mod = b.createModule(.{
        .root_source_file = b.path("src/collector/gpu/nvml.zig"),
        .target = target,
        .optimize = optimize,
    });
    gpu_col_mod.addIncludePath(b.path("include"));
    gpu_col_mod.addImport("core", core_mod);
    gpu_col_mod.addImport("util", util_mod);
    gpu_col_mod.link_libc = true;

    const ztop_g_mod = b.createModule(.{
        .root_source_file = b.path("src/main_gpu.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zkdb", .module = zkdb_mod },
            .{ .name = "core", .module = core_mod },
            .{ .name = "gpu", .module = gpu_col_mod },
            .{ .name = "util", .module = util_mod },
        },
    });
    ztop_g_mod.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    ztop_g_mod.linkSystemLibrary("nvidia-ml", .{});
    ztop_g_mod.link_libc = true;

    const ztop_g = b.addExecutable(.{
        .name = "ztop-g",
        .root_module = ztop_g_mod,
    });
    b.installArtifact(ztop_g);

    // Run steps
    const run_ztop = b.addRunArtifact(ztop);
    if (b.args) |args| run_ztop.addArgs(args);
    b.step("run", "Run ztop (CPU monitor)").dependOn(&run_ztop.step);

    const run_ztop_g = b.addRunArtifact(ztop_g);
    if (b.args) |args| run_ztop_g.addArgs(args);
    b.step("run-gpu", "Run ztop-g (GPU monitor)").dependOn(&run_ztop_g.step);

    // Tests
    const test_core = b.addTest(.{ .root_module = core_mod });
    const test_cpu = b.addTest(.{ .root_module = cpu_col_mod });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(test_core).step);
    test_step.dependOn(&b.addRunArtifact(test_cpu).step);
}
