const std = @import("std");
const Build = std.Build;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //
    // Modules
    //

    _ = b.addModule("razdaz", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
    });

    //
    // Tests
    //

    const test_step = b.step("test", "Run unit tests");
    const test_exe = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(test_exe).step);
    test_step.dependOn(&b.addInstallArtifact(test_exe, .{
        .dest_dir = .default,
        .dest_sub_path = "test",
    }).step);
}
