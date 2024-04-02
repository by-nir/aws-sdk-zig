const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod_types = b.addModule("aws-types", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = .{ .path = "src/types/root.zig" },
    });

    _ = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = .{ .path = "src/runtime/root.zig" },
        .imports = &.{
            .{ .name = "aws-types", .module = mod_types },
        },
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

    const runtime_unit_tests = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = .{ .path = "src/runtime/root.zig" },
    });
    runtime_unit_tests.root_module.addImport("aws-types", mod_types);
    test_step.dependOn(&b.addRunArtifact(runtime_unit_tests).step);
}
