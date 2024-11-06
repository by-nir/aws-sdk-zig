const std = @import("std");
const Build = std.Build;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //
    // Modules
    //

    _ = b.addModule("jarz", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("jarz/root.zig"),
    });

    _ = b.addModule("jobz", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("jobz/root.zig"),
    });

    //
    // Tests
    //

    const test_all_step = b.step("test", "Run all unit tests");

    // Jarz

    const test_jarz_step = b.step("test:jarz", "Run Jarz unit tests");
    test_all_step.dependOn(test_jarz_step);

    const test_jarz_exe = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("jarz/root.zig"),
    });
    test_jarz_step.dependOn(&b.addRunArtifact(test_jarz_exe).step);

    const debug_jarz_step = b.step("lldb:jarz", "Install Jarz LLDB binary");
    debug_jarz_step.dependOn(&b.addInstallArtifact(test_jarz_exe, .{
        .dest_dir = .{ .override = .{ .custom = "lldb" } },
        .dest_sub_path = "jarz",
    }).step);

    // Jobz

    const test_jobz_step = b.step("test:jobz", "Run Jobz unit tests");
    test_all_step.dependOn(test_jobz_step);

    const test_jobz_exe = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("jobz/root.zig"),
    });
    test_jobz_step.dependOn(&b.addRunArtifact(test_jobz_exe).step);

    const debug_jobz_step = b.step("lldb:jobz", "Install Jobz LLDB binary");
    debug_jobz_step.dependOn(&b.addInstallArtifact(test_jobz_exe, .{
        .dest_dir = .{ .override = .{ .custom = "lldb" } },
        .dest_sub_path = "jobz",
    }).step);
}
