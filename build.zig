const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("aws-types", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = .{ .path = "src/types/root.zig" },
    });

    //
    // Tests
    //

    const test_step = b.step("test", "Run unit tests");

    const types_unit_tests = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = .{ .path = "src/types/root.zig" },
    });
    test_step.dependOn(&b.addRunArtifact(types_unit_tests).step);
}
