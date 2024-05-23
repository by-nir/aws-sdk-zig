const std = @import("std");
const Build = std.Build;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("smithy", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
    });

    const tests_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
    });
    tests_step.dependOn(&b.addRunArtifact(unit_tests).step);
}
