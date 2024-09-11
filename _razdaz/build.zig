const std = @import("std");
const Build = std.Build;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //
    // Dependencies
    //

    const jarz = b.dependency("jarz", .{
        .target = target,
        .optimize = optimize,
    }).module("jarz");

    const jobz = b.dependency("jobz", .{
        .target = target,
        .optimize = optimize,
    }).module("jobz");

    //
    // Modules
    //

    const core = b.addModule("razdaz", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
        .imports = &.{
            .{ .name = "jarz", .module = jarz },
        },
    });

    _ = b.addModule("jobs", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("jobs/root.zig"),
        .imports = &.{
            .{ .name = "razdaz", .module = core },
            .{ .name = "jobz", .module = jobz },
        },
    });

    //
    // Tests
    //

    const test_step = b.step("test", "Run unit tests");

    const test_core_exe = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
    });
    test_core_exe.root_module.addImport("jarz", jarz);
    test_step.dependOn(&b.addRunArtifact(test_core_exe).step);
    test_step.dependOn(&b.addInstallArtifact(test_core_exe, .{
        .dest_dir = .default,
        .dest_sub_path = "test",
    }).step);

    const test_jobs_exe = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("jobs/root.zig"),
    });
    test_jobs_exe.root_module.addImport("razdaz", core);
    test_jobs_exe.root_module.addImport("jobz", jobz);
    test_step.dependOn(&b.addRunArtifact(test_jobs_exe).step);
}
