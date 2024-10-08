const std = @import("std");
const Build = std.Build;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //
    // Dependencies
    //

    const jobz = b.dependency("jobz", .{
        .target = target,
        .optimize = optimize,
    }).module("jobz");

    const rzdz = b.dependency("razdaz", .{
        .target = target,
        .optimize = optimize,
    });
    const razdaz = rzdz.module("razdaz");
    const razdaz_jobs = rzdz.module("jobs");

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
            .{ .name = "razdaz", .module = razdaz },
            .{ .name = "razdaz/jobs", .module = razdaz_jobs },
            .{ .name = "runtime", .module = runtime },
        },
    });

    //
    // Tests
    //

    const test_all_step = b.step("test", "Run all unit tests");

    const test_runtime_step = b.step("test:runtime", "Run codegen unit tests");
    const test_runtime_exe = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("runtime/root.zig"),
    });
    test_runtime_exe.root_module.addImport("mvzr", mvzr);
    test_runtime_step.dependOn(&b.addRunArtifact(test_runtime_exe).step);
    test_all_step.dependOn(test_runtime_step);
    test_all_step.dependOn(&b.addInstallArtifact(test_runtime_exe, .{
        .dest_dir = .{ .override = .{ .custom = "test" } },
        .dest_sub_path = "runtime",
    }).step);

    const test_codegen_step = b.step("test:codegen", "Run codegen unit tests");
    const test_codegen_exe = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("codegen/root.zig"),
    });
    test_codegen_exe.root_module.addImport("jobz", jobz);
    test_codegen_exe.root_module.addImport("razdaz", razdaz);
    test_codegen_exe.root_module.addImport("razdaz/jobs", razdaz_jobs);
    test_codegen_exe.root_module.addImport("runtime", runtime);
    test_codegen_step.dependOn(&b.addRunArtifact(test_codegen_exe).step);
    test_all_step.dependOn(test_codegen_step);
    test_all_step.dependOn(&b.addInstallArtifact(test_codegen_exe, .{
        .dest_dir = .{ .override = .{ .custom = "test" } },
        .dest_sub_path = "codegen",
    }).step);
}
