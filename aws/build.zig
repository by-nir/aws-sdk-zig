const std = @import("std");
const Build = std.Build;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize: std.builtin.OptimizeMode = .Debug;

    //
    // Dependencies
    //

    const jobz = b.dependency("bitz", .{
        .target = target,
        .optimize = optimize,
    }).module("jobz");

    const cdmd = b.dependency("codmod", .{
        .target = target,
        .optimize = optimize,
    });
    const codmod = cdmd.module("codmod");
    const codmod_jobs = cdmd.module("jobs");

    const smithy = b.dependency("smithy", .{
        .target = target,
        .optimize = optimize,
    });
    const smithy_runtime = smithy.module("runtime");
    const smithy_codegen = smithy.module("codegen");

    const xml = b.dependency("xml", .{
        .target = target,
        .optimize = optimize,
    }).module("xml");

    //
    // Modules
    //

    _ = b.addModule("runtime", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("runtime/root.zig"),
        .imports = &.{
            .{ .name = "smithy/runtime", .module = smithy_runtime },
            .{ .name = "xml", .module = xml },
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
    codegen_exe.root_module.addImport("jobz", jobz);
    codegen_exe.root_module.addImport("codmod", codmod);
    codegen_exe.root_module.addImport("codmod/jobs", codmod_jobs);
    codegen_exe.root_module.addImport("smithy/codegen", smithy_codegen);
    b.installArtifact(codegen_exe);

    //
    // Tests
    //

    const test_all_step = b.step("test", "Run all unit tests");

    // Runtime

    const test_runtime_step = b.step("test:runtime", "Run SDK runtime unit tests");
    test_all_step.dependOn(test_runtime_step);

    const test_runtime_exe = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("runtime/root.zig"),
    });
    test_runtime_step.dependOn(&b.addRunArtifact(test_runtime_exe).step);
    test_runtime_exe.root_module.addImport("smithy/runtime", smithy_runtime);
    test_runtime_exe.root_module.addImport("xml", xml);

    const debug_runtime_step = b.step("lldb:runtime", "Install runtime LLDB binary");
    debug_runtime_step.dependOn(&b.addInstallArtifact(test_runtime_exe, .{
        .dest_dir = .{ .override = .{ .custom = "lldb" } },
        .dest_sub_path = "runtime",
    }).step);

    // Codgen

    const test_codegen_step = b.step("test:codegen", "Run codegen unit tests");
    test_all_step.dependOn(test_codegen_step);

    const test_codegen_exe = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("codegen/main.zig"),
    });
    test_codegen_step.dependOn(&b.addRunArtifact(test_codegen_exe).step);
    test_codegen_exe.root_module.addImport("jobz", jobz);
    test_codegen_exe.root_module.addImport("codmod", codmod);
    test_codegen_exe.root_module.addImport("codmod/jobs", codmod_jobs);
    test_codegen_exe.root_module.addImport("smithy/codegen", smithy_codegen);

    const debug_codegen_step = b.step("lldb:codegen", "Install codegen LLDB binary");
    debug_codegen_step.dependOn(&b.addInstallArtifact(test_codegen_exe, .{
        .dest_dir = .{ .override = .{ .custom = "lldb" } },
        .dest_sub_path = "codegen",
    }).step);
}
