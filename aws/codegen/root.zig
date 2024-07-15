const std = @import("std");
const fs = std.fs;
const smithy = @import("smithy");
const pipez = smithy.pipez;
const Task = pipez.Task;
const Delegate = pipez.Delegate;
const Pipeline = pipez.Pipeline;
const files_tasks = smithy.files_tasks;
const sdk_client = @import("tasks/client.zig");
const conf_region = @import("tasks/config_region.zig");
const conf_partition = @import("tasks/config_partitions.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    defer _ = gpa.deinit();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    if (args.len < 4) {
        return error.MissingPathsArgs;
    }

    var src_dir = try fs.openDirAbsolute(args[1], .{ .iterate = true });
    defer src_dir.close();

    var out_aws_dir = try fs.cwd().makeOpenPath(args[2], .{});
    defer out_aws_dir.close();

    var out_sdk_dir = try fs.cwd().makeOpenPath(args[3], .{});
    defer out_sdk_dir.close();

    var pipeline = try Pipeline.init(alloc, .{ .invoker = sdk_client.pipeline_invoker });
    defer pipeline.deinit();

    const whitelist = args[4..args.len];
    try pipeline.runTask(Aws, .{ src_dir, out_aws_dir, out_sdk_dir, whitelist });
}

const Aws = Task.Define("AWS", awsTask, .{});
fn awsTask(
    self: *const Delegate,
    src_dir: fs.Dir,
    out_aws_dir: fs.Dir,
    out_sdk_dir: fs.Dir,
    whitelist: []const []const u8,
) !void {
    try files_tasks.defineWorkDir(self, out_aws_dir);

    var region_defs = std.ArrayList(conf_region.RegionDef).init(self.alloc());

    try self.evaluate(conf_partition.Partitions, .{ "partitions.gen.zig", files_tasks.FileOptions{
        .delete_on_error = true,
    }, src_dir, &region_defs });

    const RegionsCodegen = files_tasks.WriteFile.Chain(conf_region.RegionsCodegen, .sync);
    try self.evaluate(RegionsCodegen, .{ "region.gen.zig", files_tasks.FileOptions{
        .delete_on_error = true,
    }, try region_defs.toOwnedSlice() });

    try files_tasks.overrideWorkDir(self, out_sdk_dir);
    try self.evaluate(sdk_client.Sdk, .{ src_dir, whitelist });
}

test {
    _ = @import("integrate/auth.zig");
    _ = @import("integrate/cloudformation.zig");
    _ = @import("integrate/core.zig");
    _ = @import("integrate/endpoints.zig");
    _ = @import("integrate/gateway.zig");
    _ = @import("integrate/iam.zig");
    _ = @import("integrate/protocols.zig");
    _ = @import("integrate/rules.zig");
    _ = conf_partition;
    _ = conf_region;
    _ = sdk_client;
}
