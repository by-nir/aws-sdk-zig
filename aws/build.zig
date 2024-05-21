const std = @import("std");
const Build = std.Build;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const smithy = b.dependency("smithy-zig", .{
        .target = target,
        .optimize = optimize,
    });

    const https12 = b.dependency("https12", .{
        .target = target,
        .optimize = optimize,
    });

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
            .{ .name = "smithy", .module = smithy.module("client") },
            .{ .name = "https12", .module = https12.module("zig-tls12") },
        },
    });

    const codegen_exe = b.addExecutable(.{
        .name = "codegen-sdk",
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("codegen/client.zig"),
    });
    codegen_exe.root_module.addImport("smithy", smithy.module("codegen"));
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
    test_client_mdl.root_module.addImport("smithy", smithy.module("client"));
    test_client_mdl.root_module.addImport("https12", https12.module("zig-tls12"));
    test_runtime_step.dependOn(&b.addRunArtifact(test_client_mdl).step);

    const test_codegen_step = b.step("test:codegen", "Run codegen unit tests");
    const test_codegen_exe = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("codegen/client.zig"),
    });
    test_codegen_exe.root_module.addImport("smithy", smithy.module("codegen"));
    test_codegen_step.dependOn(&b.addRunArtifact(test_codegen_exe).step);
}
