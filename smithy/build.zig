const std = @import("std");
const Build = std.Build;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("client", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("client/root.zig"),
    });

    _ = b.addModule("codegen", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("codegen/root.zig"),
    });

    //
    // Tests
    //

    const tests_step = b.step("test", "Run unit tests");

    const test_client_mdl = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("client/root.zig"),
    });
    tests_step.dependOn(&b.addRunArtifact(test_client_mdl).step);

    const test_codegen_mdl = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("codegen/root.zig"),
    });
    tests_step.dependOn(&b.addRunArtifact(test_codegen_mdl).step);
}
