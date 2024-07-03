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
    });
    const smithy_runtime = smithy.module("runtime");
    const smithy_codegen = smithy.module("codegen");

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
            .{ .name = "smithy", .module = smithy_runtime },
            .{ .name = "aws-types", .module = types_mdl },
        },
    });

    //
    // Artifacts
    //

    const partitions_exe = b.addExecutable(.{
        .name = "codegen-partitions",
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("codegen/tasks/partitions.zig"),
    });
    partitions_exe.root_module.addImport("smithy", smithy_codegen);
    b.installArtifact(partitions_exe);

    const sdk_exe = b.addExecutable(.{
        .name = "codegen-sdk",
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("codegen/sdk.zig"),
    });
    sdk_exe.root_module.addImport("smithy", smithy_codegen);
    b.installArtifact(sdk_exe);

    //
    // Tests
    //

    const test_all_step = b.step("test", "Run all unit tests");

    const test_runtime_step = b.step("test:runtime", "Run runtime unit tests");
    test_all_step.dependOn(test_runtime_step);

    const test_types_mdl = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("types/root.zig"),
    });
    test_runtime_step.dependOn(&b.addRunArtifact(test_types_mdl).step);
    test_all_step.dependOn(&b.addInstallArtifact(test_types_mdl, .{
        .dest_dir = .{ .override = .{ .custom = "test" } },
        .dest_sub_path = "runtime-types",
    }).step);

    const test_client_mdl = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("client/root.zig"),
    });
    test_client_mdl.root_module.addImport("smithy", smithy_runtime);
    test_client_mdl.root_module.addImport("aws-types", types_mdl);
    test_runtime_step.dependOn(&b.addRunArtifact(test_client_mdl).step);
    test_all_step.dependOn(&b.addInstallArtifact(test_client_mdl, .{
        .dest_dir = .{ .override = .{ .custom = "test" } },
        .dest_sub_path = "runtime-client",
    }).step);

    const test_codegen_step = b.step("test:codegen", "Run codegen unit tests");
    test_all_step.dependOn(test_codegen_step);

    const test_gen_partitions_exe = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("codegen/tasks/partitions.zig"),
    });
    test_gen_partitions_exe.root_module.addImport("smithy", smithy_codegen);
    test_codegen_step.dependOn(&b.addRunArtifact(test_gen_partitions_exe).step);
    test_all_step.dependOn(&b.addInstallArtifact(test_gen_partitions_exe, .{
        .dest_dir = .{ .override = .{ .custom = "test" } },
        .dest_sub_path = "codegen-partitions",
    }).step);

    const test_gen_sdk_exe = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("codegen/sdk.zig"),
    });
    test_gen_sdk_exe.root_module.addImport("smithy", smithy_codegen);
    test_codegen_step.dependOn(&b.addRunArtifact(test_gen_sdk_exe).step);
    test_all_step.dependOn(&b.addInstallArtifact(test_gen_sdk_exe, .{
        .dest_dir = .{ .override = .{ .custom = "test" } },
        .dest_sub_path = "codegen-sdk",
    }).step);
}
