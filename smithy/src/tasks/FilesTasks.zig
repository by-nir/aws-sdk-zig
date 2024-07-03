const std = @import("std");
const fs = std.fs;
const testing = std.testing;
const test_alloc = testing.allocator;
const pipez = @import("../pipeline/root.zig");
const Delegate = pipez.Delegate;
const AbstractTask = pipez.AbstractTask;
const md = @import("../codegen/md.zig");
const zig = @import("../codegen/zig/scope.zig");
const Writer = @import("../codegen/CodegenWriter.zig");

const FilesScope = enum {
    work_dir,
};

/// Returns the scope’s active directory.
/// Fallbacks to the executable’s current working directory.
pub fn getWorkDir(delegate: *const Delegate) fs.Dir {
    return delegate.readValue(fs.Dir, FilesScope.work_dir) orelse fs.cwd();
}

/// Use `FilesTasks.getWorkDir()` to get the opened directory.
pub const OpenDir = AbstractTask(openDirTask, .{});

pub const OpenDirOptions = struct {
    iterable: bool = false,
    delete_on_error: bool = false,
    create_on_not_found: bool = false,
};

fn openDirTask(
    self: *const Delegate,
    sub_path: []const u8,
    options: OpenDirOptions,
    task: *const fn () anyerror!void,
) !void {
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
    try task();
}

pub const WriteFile = AbstractTask(writeFileTask, .{
    .varyings = &.{std.io.AnyWriter},
});

pub const FileOptions = struct {
    delete_on_error: bool = false,
};

fn writeFileTask(
    self: *const Delegate,
    sub_path: []const u8,
    options: FileOptions,
    task: *const fn (struct { std.io.AnyWriter }) anyerror!void,
) !void {
    const cwd = getWorkDir(self);
    const file = try cwd.createFile(sub_path, .{});
    errdefer if (options.delete_on_error) cwd.deleteFile(sub_path) catch |err| {
        std.log.err("Deleting file `{s}` failed: {s}", .{ sub_path, @errorName(err) });
    };
    defer file.close();
    var buffer = std.io.bufferedWriter(file.writer());

    try task(.{buffer.writer().any()});
    try buffer.flush();
}
