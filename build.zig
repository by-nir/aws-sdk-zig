const std = @import("std");
const Build = std.Build;

const Options = struct {
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const smithy = b.dependency("smithy", .{
        .target = target,
        .optimize = optimize,
    }).module("runtime");

    const aws_runtime = b.dependency("aws", .{
        .target = target,
        .optimize = optimize,
    }).module("runtime");

    //
    // SDK
    //

    b.modules.put("aws", aws_runtime) catch {};

    const sdk_path = "sdk";
    var sdk_dir = std.fs.openDirAbsolute(b.path(sdk_path).getPath(b), .{ .iterate = true }) catch {
        @panic("Open dir error");
    };
    defer sdk_dir.close();

    // Services
    var it = sdk_dir.iterateAssumeFirstIteration();
    while (it.next() catch @panic("Dir iterator error")) |entry| {
        if (entry.kind != .directory) continue;
        addSdkClient(b, .{
            .target = target,
            .optimize = optimize,
        }, sdk_path, entry.name, smithy, aws_runtime);
    }
}

fn addSdkClient(
    b: *std.Build,
    options: Options,
    dir: []const u8,
    name: []const u8,
    smithy: *Build.Module,
    runtime: *Build.Module,
) void {
    // Client
    const path = b.path(b.fmt("{s}/{s}/client.zig", .{ dir, name }));
    _ = b.addModule(
        b.fmt("sdk/{s}", .{name}),
        .{
            .target = options.target,
            .optimize = options.optimize,
            .root_source_file = path,
            .imports = &.{
                .{ .name = "smithy", .module = smithy },
                .{ .name = "aws-runtime", .module = runtime },
            },
        },
    );

    // Tests
    const test_step = b.step(
        b.fmt("test:sdk-{s}", .{name}),
        b.fmt("Run `{s}` SDK unit tests", .{name}),
    );
    const unit_tests = b.addTest(.{
        .target = options.target,
        .optimize = options.optimize,
        .root_source_file = path,
    });
    unit_tests.root_module.addImport("smithy", smithy);
    unit_tests.root_module.addImport("aws-runtime", runtime);
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
}
