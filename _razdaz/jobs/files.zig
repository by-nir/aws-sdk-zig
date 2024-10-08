const std = @import("std");
const fs = std.fs;
const testing = std.testing;
const test_alloc = testing.allocator;
const jobz = @import("jobz");
const Task = jobz.Task;
const Delegate = jobz.Delegate;
const AbstractTask = jobz.AbstractTask;
const AbstractEval = jobz.AbstractEval;

const FilesScope = enum {
    work_dir,
};

pub fn defineWorkDir(delegate: *const Delegate, dir: fs.Dir) !void {
    try delegate.defineValue(fs.Dir, FilesScope.work_dir, dir);
}

pub fn overrideWorkDir(delegate: *const Delegate, dir: fs.Dir) !void {
    try delegate.writeValue(fs.Dir, FilesScope.work_dir, dir);
}

/// Returns the scope’s active directory.
/// Fallbacks to the executable’s current working directory.
pub fn getWorkDir(delegate: *const Delegate) fs.Dir {
    return delegate.readValue(fs.Dir, FilesScope.work_dir) orelse fs.cwd();
}

pub const DirOptions = struct {
    iterable: bool = false,
    delete_on_error: bool = false,
    create_on_not_found: bool = false,
};

/// Use `FilesTasks.getWorkDir()` to get the opened directory.
pub const OpenDir = AbstractTask.Define("Open Directory", openDirTask, .{});
fn openDirTask(
    self: *const Delegate,
    sub_path: []const u8,
    options: DirOptions,
    task: AbstractEval(&.{}, anyerror!void),
) anyerror!void {
    const cwd = getWorkDir(self);
    var dir = switch (options.create_on_not_found) {
        true => try cwd.makeOpenPath(sub_path, .{ .iterate = options.iterable }),
        false => try cwd.openDir(sub_path, .{ .iterate = options.iterable }),
    };
    errdefer if (options.delete_on_error) cwd.deleteTree(sub_path) catch |err| {
        std.log.err("Deleting directory `{s}` failed: {s}", .{ sub_path, @errorName(err) });
    };
    defer dir.close();

    try self.defineValue(fs.Dir, FilesScope.work_dir, dir);
    try task.evaluate(.{});
}

pub const FileOptions = struct {
    delete_on_error: bool = false,
};

pub const WriteFile = AbstractTask.Define("Write File", writeFileTask, .{
    .varyings = &.{std.io.AnyWriter},
});
fn writeFileTask(
    self: *const Delegate,
    sub_path: []const u8,
    options: FileOptions,
    task: AbstractEval(&.{std.io.AnyWriter}, anyerror!void),
) anyerror!void {
    const cwd = getWorkDir(self);
    const file = try cwd.createFile(sub_path, .{});
    errdefer if (options.delete_on_error) cwd.deleteFile(sub_path) catch |err| {
        std.log.err("Deleting file `{s}` failed: {s}", .{ sub_path, @errorName(err) });
    };
    defer file.close();
    var buffer = std.io.bufferedWriter(file.writer());

    try task.evaluate(.{buffer.writer().any()});
    try buffer.flush();
}

pub fn evaluateWriteFile(
    allocator: std.mem.Allocator,
    pipeline: *jobz.Pipeline,
    comptime task: Task,
    input: AbstractTask.ExtractChildInput(task),
) ![]const u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    errdefer buffer.deinit();

    try pipeline.runTask(AbstractTask.ExtractChildTask(task), .{buffer.writer().any()} ++ input);
    return buffer.toOwnedSlice();
}

test "evaluateWriteFile" {
    const TestWrite = WriteFile.Task("Test Write", struct {
        fn f(_: *const Delegate, writer: std.io.AnyWriter, in: []const u8) anyerror!void {
            try writer.print("foo {s}", .{in});
        }
    }.f, .{});

    var tester = try jobz.PipelineTester.init(.{});
    defer tester.deinit();

    const output = try evaluateWriteFile(test_alloc, tester.pipeline, TestWrite, .{"bar"});
    defer test_alloc.free(output);
    try testing.expectEqualStrings("foo bar", output);
}
