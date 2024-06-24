const std = @import("std");
const Build = std.Build;

const Options = struct {
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const runtime = b.dependency("aws-runtime", .{
        .target = target,
        .optimize = optimize,
    });
    const aws_types = runtime.module("types");
    const aws_client = runtime.module("client");

    b.modules.put("aws-types", aws_types) catch {};

    //
    // SDK
    //

    const sdk_path = "sdk";
    var sdk_dir = std.fs.openDirAbsolute(b.path(sdk_path).getPath(b), .{ .iterate = true }) catch {
        @panic("Open dir error");
    };
    defer sdk_dir.close();

    // Partitions
    const sdk_partitions = b.addModule("sdk-partitions", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("sdk/partitions.zig"),
    });

    // Clients
    var it = sdk_dir.iterateAssumeFirstIteration();
    while (it.next() catch @panic("Dir iterator error")) |entry| {
        if (entry.kind != .directory) continue;
        addSdkClient(b, .{
            .target = target,
            .optimize = optimize,
        }, sdk_path, entry.name, aws_types, aws_client, sdk_partitions);
    }
}

fn addSdkClient(
    b: *std.Build,
    options: Options,
    dir: []const u8,
    name: []const u8,
    aws_types: *Build.Module,
    aws_client: *Build.Module,
    sdk_partitions: *Build.Module,
) void {
    // Client
    const path = b.path(b.fmt("{s}/{s}/client.zig", .{ dir, name }));
    _ = b.addModule(
        b.fmt("aws-{s}", .{name}),
        .{
            .target = options.target,
            .optimize = options.optimize,
            .root_source_file = path,
            .imports = &.{
                .{ .name = "aws-types", .module = aws_types },
                .{ .name = "aws-runtime", .module = aws_client },
                .{ .name = "sdk-partitions", .module = sdk_partitions },
            },
        },
    );

    // Tests
    const test_step = b.step(
        b.fmt("test:{s}", .{name}),
        b.fmt("Run `{s}` SDK unit tests", .{name}),
    );
    const unit_tests = b.addTest(.{
        .target = options.target,
        .optimize = options.optimize,
        .root_source_file = path,
    });
    unit_tests.root_module.addImport("aws-types", aws_types);
    unit_tests.root_module.addImport("aws-runtime", aws_client);
    unit_tests.root_module.addImport("sdk-partitions", sdk_partitions);
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
}
