const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod_types = b.addModule("aws-types", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = .{ .path = "src/types/root.zig" },
    });

    // See runtime client for more information
    const https12 = b.dependency("https12", .{
        .target = target,
        .optimize = optimize,
    });

    _ = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = .{ .path = "src/runtime/root.zig" },
        .imports = &.{
            .{ .name = "aws-types", .module = mod_types },
            .{ .name = "https12", .module = https12.module("zig-tls12") },
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
    runtime_unit_tests.root_module.addImport("https12", https12.module("zig-tls12"));
    test_step.dependOn(&b.addRunArtifact(runtime_unit_tests).step);
}
