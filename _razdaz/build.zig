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

    //
    // Modules
    //

    _ = b.addModule("razdaz", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
        .imports = &.{
            .{ .name = "jarz", .module = jarz },
        },
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
    test_exe.root_module.addImport("jarz", jarz);
    test_step.dependOn(&b.addRunArtifact(test_exe).step);
    test_step.dependOn(&b.addInstallArtifact(test_exe, .{
        .dest_dir = .default,
        .dest_sub_path = "test",
    }).step);
}
