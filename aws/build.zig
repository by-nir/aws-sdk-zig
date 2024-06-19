const std = @import("std");
const Build = std.Build;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //
    // Dependencies
    //

    const smithy = b.dependency("smithy", .{
        .target = target,
        .optimize = optimize,
    }).module("smithy");

    //
    // Modules
    //

    const types_mdl = b.addModule("types", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("types/root.zig"),
    });

    _ = b.addModule("client", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("client/root.zig"),
        .imports = &.{
            .{ .name = "aws-types", .module = types_mdl },
        },
    });

    //
    // Artifacts
    //

    const codegen_exe = b.addExecutable(.{
        .name = "codegen-sdk",
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("codegen/client.zig"),
    });
    codegen_exe.root_module.addImport("smithy", smithy);
    b.installArtifact(codegen_exe);

    //
    // Tests
    //

    const test_runtime_step = b.step("test:runtime", "Run runtime unit tests");
    const test_types_mdl = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("types/root.zig"),
    });
    test_runtime_step.dependOn(&b.addRunArtifact(test_types_mdl).step);
    const test_client_mdl = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("client/root.zig"),
    });
    test_client_mdl.root_module.addImport("aws-types", types_mdl);
    test_runtime_step.dependOn(&b.addRunArtifact(test_client_mdl).step);

    const test_codegen_step = b.step("test:codegen", "Run codegen unit tests");
    const test_codegen_exe = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("codegen/client.zig"),
    });
    test_codegen_exe.root_module.addImport("smithy", smithy);
    test_codegen_step.dependOn(&b.addRunArtifact(test_codegen_exe).step);
}
