const std = @import("std");
const Build = std.Build;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //
    // Dependencies
    //

    const pipez = b.dependency("pipez", .{
        .target = target,
        .optimize = optimize,
    }).module("pipez");

    const codegen = b.dependency("codegen", .{
        .target = target,
        .optimize = optimize,
    }).module("codegen");

    const smithy = b.dependency("smithy", .{
        .target = target,
        .optimize = optimize,
    });
    const smithy_runtime = smithy.module("runtime");
    const smithy_codegen = smithy.module("codegen");

    //
    // Modules
    //

    _ = b.addModule("runtime", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("runtime/root.zig"),
        .imports = &.{
            .{ .name = "smithy/runtime", .module = smithy_runtime },
        },
    });

    //
    // Artifacts
    //

    const codegen_exe = b.addExecutable(.{
        .name = "aws-codegen",
        .target = target,
        .optimize = .Debug,
        .error_tracing = true,
        .root_source_file = b.path("codegen/main.zig"),
    });
    codegen_exe.root_module.addImport("pipez", pipez);
    codegen_exe.root_module.addImport("codegen", codegen);
    codegen_exe.root_module.addImport("smithy/codegen", smithy_codegen);
    b.installArtifact(codegen_exe);

    //
    // Tests
    //

    const test_all_step = b.step("test", "Run all unit tests");

    const test_runtime_step = b.step("test:runtime", "Run SDK runtime unit tests");
    test_all_step.dependOn(test_runtime_step);

    const test_runtime_mdl = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("runtime/root.zig"),
    });
    test_runtime_mdl.root_module.addImport("smithy/runtime", smithy_runtime);
    test_runtime_step.dependOn(&b.addRunArtifact(test_runtime_mdl).step);
    test_all_step.dependOn(&b.addInstallArtifact(test_runtime_mdl, .{
        .dest_dir = .{ .override = .{ .custom = "test" } },
        .dest_sub_path = "runtime",
    }).step);

    const test_codegen_step = b.step("test:codegen", "Run codegen unit tests");
    test_all_step.dependOn(test_codegen_step);

    const test_codegen_exe = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("codegen/main.zig"),
    });
    test_codegen_exe.root_module.addImport("pipez", pipez);
    test_codegen_exe.root_module.addImport("codegen", codegen);
    test_codegen_exe.root_module.addImport("smithy/codegen", smithy_codegen);
    test_codegen_step.dependOn(&b.addRunArtifact(test_codegen_exe).step);
    test_all_step.dependOn(&b.addInstallArtifact(test_codegen_exe, .{
        .dest_dir = .{ .override = .{ .custom = "test" } },
        .dest_sub_path = "codegen",
    }).step);
}
