const std = @import("std");
const Build = std.Build;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //
    // Dependencies
    //

    const jobz = b.dependency("bitz", .{
        .target = target,
        .optimize = optimize,
    }).module("jobz");

    const cdmd = b.dependency("codmod", .{
        .target = target,
        .optimize = optimize,
    });
    const codmod = cdmd.module("codmod");
    const codmod_jobs = cdmd.module("jobs");

    const mvzr = b.dependency("mvzr", .{
        .target = target,
        .optimize = optimize,
    }).module("mvzr");

    //
    // Modules
    //

    const runtime = b.addModule("runtime", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("runtime/root.zig"),
        .imports = &.{
            .{ .name = "mvzr", .module = mvzr },
        },
    });

    _ = b.addModule("codegen", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("codegen/root.zig"),
        .imports = &.{
            .{ .name = "jobz", .module = jobz },
            .{ .name = "codmod", .module = codmod },
            .{ .name = "codmod/jobs", .module = codmod_jobs },
            .{ .name = "runtime", .module = runtime },
        },
    });

    //
    // Tests
    //

    const test_all_step = b.step("test", "Run all unit tests");

    // Runtime

    const test_runtime_step = b.step("test:runtime", "Run runtime unit tests");
    test_all_step.dependOn(test_runtime_step);

    const test_runtime_exe = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("runtime/root.zig"),
    });
    test_runtime_step.dependOn(&b.addRunArtifact(test_runtime_exe).step);
    test_runtime_exe.root_module.addImport("mvzr", mvzr);

    const debug_runtime_step = b.step("lldb:runtime", "Install runtime LLDB binary");
    debug_runtime_step.dependOn(&b.addInstallArtifact(test_runtime_exe, .{
        .dest_dir = .{ .override = .{ .custom = "lldb" } },
        .dest_sub_path = "runtime",
    }).step);

    // Codegen

    const test_codegen_step = b.step("test:codegen", "Run codegen unit tests");
    test_all_step.dependOn(test_codegen_step);
    const test_codegen_exe = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("codegen/root.zig"),
    });
    test_codegen_step.dependOn(&b.addRunArtifact(test_codegen_exe).step);
    test_codegen_exe.root_module.addImport("jobz", jobz);
    test_codegen_exe.root_module.addImport("codmod", codmod);
    test_codegen_exe.root_module.addImport("codmod/jobs", codmod_jobs);
    test_codegen_exe.root_module.addImport("runtime", runtime);

    const debug_codegen_step = b.step("lldb:codegen", "Install codegen LLDB binary");
    debug_codegen_step.dependOn(&b.addInstallArtifact(test_codegen_exe, .{
        .dest_dir = .{ .override = .{ .custom = "lldb" } },
        .dest_sub_path = "codegen",
    }).step);
}
