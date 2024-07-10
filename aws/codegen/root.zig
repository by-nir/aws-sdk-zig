const std = @import("std");
const fs = std.fs;
const smithy = @import("smithy");
const pipez = smithy.pipez;
const Task = pipez.Task;
const Delegate = pipez.Delegate;
const Pipeline = pipez.Pipeline;
const files_tasks = smithy.files_tasks;
const sdk = @import("tasks/sdk.zig");
const Partitions = @import("tasks/partitions.zig").Partitions;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    defer _ = gpa.deinit();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    if (args.len < 3) {
        return error.MissingPathsArgs;
    }

    var src_dir = try fs.openDirAbsolute(args[1], .{ .iterate = true });
    defer src_dir.close();

    var out_dir = try fs.cwd().makeOpenPath(args[2], .{});
    defer out_dir.close();

    var pipeline = try Pipeline.init(alloc, .{ .invoker = sdk.pipeline_invoker });
    defer pipeline.deinit();

    const whitelist = args[3..args.len];
    try pipeline.runTask(Aws, .{ src_dir, out_dir, whitelist });
}

const Aws = Task.Define("AWS", awsTask, .{});
fn awsTask(self: *const Delegate, src_dir: fs.Dir, out_dir: fs.Dir, whitelist: []const []const u8) !void {
    try files_tasks.defineWorkDir(self, out_dir);

    try self.schedule(sdk.Sdk, .{ src_dir, whitelist });

    try self.schedule(Partitions, .{ "partitions.zig", files_tasks.FileOptions{
        .delete_on_error = true,
    }, src_dir });
}
