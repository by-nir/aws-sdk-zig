//! Writer with a hierarchical prefix.

const std = @import("std");
const fmt = std.fmt;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;
const test_alloc = testing.allocator;

const Self = @This();

pub const Options = struct {
    wrap_soft: u8 = 80,
    wrap_hard: u8 = 120,
    prefix: []const u8 = &.{},
};

pub const ListOptions = struct {
    delimiter: u8 = ',',
    /// Value to append the current line’s prefix.
    multiline: ?[]const u8 = null,
    /// Specifier as defined by `std.fmt`.
    item_format: []const u8 = "",
};

options: Options,
output: std.io.AnyWriter,
parent: ?*const Self = null,
deferred: *std.ArrayList([]const u8) = undefined,

pub fn init(output: std.io.AnyWriter, options: Options) Self {
    return .{
        .output = output,
        .options = options,
    };
}

pub fn writeByte(self: Self, byte: u8) !void {
    try self.output.writeByte(byte);
}

test "writeByte" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    const writer = init(buffer.writer().any(), .{});
    try writer.writeByte('f');
    try testing.expectEqualStrings("f", buffer.items);
}

pub fn writeAll(self: Self, bytes: []const u8) !void {
    try self.output.writeAll(bytes);
}

test "writeAll" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    const writer = init(buffer.writer().any(), .{});
    try writer.writeAll("foo");
    try testing.expectEqualStrings("foo", buffer.items);
}

pub fn writeFmt(self: Self, comptime format: []const u8, args: anytype) !void {
    try self.output.print("{s}", .{self.options.prefix});
    try self.output.print(format, args);
}

test "writeFmt" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    const writer = init(buffer.writer().any(), .{
        .prefix = "  ",
    });
    try writer.writeFmt("{x}", .{16});
    try testing.expectEqualStrings("  10", buffer.items);
}

pub fn writeList(self: Self, comptime T: type, items: []const T, comptime options: ListOptions) !void {
    if (items.len == 0) return;
    const writer = self.output;

    var deli_buffer: [64]u8 = undefined;
    const prefix: []const u8, const deli: []const u8 = if (options.multiline) |append| blk: {
        const current = self.options.prefix;
        const total = 2 + current.len + append.len;
        assert(total <= 64);

        deli_buffer[0] = options.delimiter;
        deli_buffer[1] = '\n';
        @memcpy(deli_buffer[2..][0..current.len], current);
        @memcpy(deli_buffer[2 + current.len ..][0..append.len], append);
        break :blk .{ deli_buffer[1..total], deli_buffer[0..total] };
    } else .{ self.options.prefix, &.{ options.delimiter, ' ' } };

    for (items, 0..) |item, i| {
        if (i > 0) {
            try writer.print("{s}{" ++ options.item_format ++ "}", .{ deli, item });
        } else if (options.multiline != null) {
            try writer.print("{s}{" ++ options.item_format ++ "}", .{ prefix, item });
        } else {
            try writer.print("{" ++ options.item_format ++ "}", .{item});
        }
    }

    if (options.multiline != null) {
        try writer.writeByte(options.delimiter);
    }
}

test "writeList" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    errdefer buffer.deinit();

    var writer = init(buffer.writer().any(), .{});
    try writer.writeList([]const u8, &.{ "foo", "bar", "baz" }, .{
        .item_format = "s",
    });
    try testing.expectEqualStrings("foo, bar, baz", buffer.items);
    buffer.clearAndFree();

    writer = init(buffer.writer().any(), .{
        .prefix = "// ",
    });
    try writer.writeList([]const u8, &.{ "foo", "bar", "baz" }, .{
        .item_format = "s",
        .multiline = "- ",
    });
    try testing.expectEqualStrings("\n" ++
        \\// - foo,
        \\// - bar,
        \\// - baz,
    , buffer.items);
    buffer.clearAndFree();
}

pub fn prefixedAll(self: Self, bytes: []const u8) !void {
    try self.output.print("{s}{s}", .{ self.options.prefix, bytes });
}

test "prefixedAll" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    const writer = init(buffer.writer().any(), .{
        .prefix = "  ",
    });
    try writer.prefixedAll("foo");
    try testing.expectEqualStrings("  foo", buffer.items);
}

pub fn prefixedFmt(self: Self, comptime format: []const u8, args: anytype) !void {
    try self.output.print("{s}", .{self.options.prefix});
    try self.output.print(format, args);
}

test "prefixedFmt" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    const writer = init(buffer.writer().any(), .{
        .prefix = "  ",
    });
    try writer.prefixedFmt("{x}", .{16});
    try testing.expectEqualStrings("  10", buffer.items);
}

pub fn lineAll(self: Self, bytes: []const u8) !void {
    try self.output.print("\n{s}{s}", .{ self.options.prefix, bytes });
}

test "lineAll" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    const writer = init(buffer.writer().any(), .{
        .prefix = "  ",
    });
    try writer.lineAll("foo");
    try testing.expectEqualStrings("\n  foo", buffer.items);
}

pub fn lineFmt(self: Self, comptime format: []const u8, args: anytype) !void {
    try self.output.print("\n{s}", .{self.options.prefix});
    try self.output.print(format, args);
}

test "lineFmt" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    const writer = init(buffer.writer().any(), .{
        .prefix = "  ",
    });
    try writer.lineFmt("{x}", .{16});
    try testing.expectEqualStrings("\n  10", buffer.items);
}

pub fn lineBreak(self: Self) !void {
    try self.output.print("\n{s}", .{self.options.prefix});
}

test "lineBreak" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    const writer = init(buffer.writer().any(), .{
        .prefix = "  ",
    });
    try writer.lineBreak();
    try testing.expectEqualStrings("\n  ", buffer.items);
}

/// Returns a new writer context with the extended prefix.
/// Call `popPrefix()` to restore the previous context.
pub fn appendPrefix(self: *const Self, allocator: Allocator, append: []const u8) !*const Self {
    assert(append.len > 0);
    const old_prefix = self.options.prefix;
    var new_prefix = try allocator.alloc(u8, old_prefix.len + append.len);
    @memcpy(new_prefix[0..old_prefix.len], old_prefix);
    @memcpy(new_prefix[old_prefix.len..][0..append.len], append);

    var context = try allocator.create(Self);
    context.* = .{
        .output = self.output,
        .options = self.options,
        .parent = self,
        .deferred = try allocator.create(std.ArrayList([]const u8)),
    };
    context.options.prefix = new_prefix;
    context.deferred.* = std.ArrayList([]const u8).init(allocator);
    return context;
}

/// Restores the previous prefix context and writes the deferred lines to it.
pub fn pop(self: *const Self) !*const Self {
    const alloc = self.ctxAllocator();
    defer {
        self.deferred.deinit();
        alloc.free(self.options.prefix);
        alloc.destroy(self.deferred);
        alloc.destroy(self);
    }
    for (self.deferred.items) |bytes| {
        try self.output.writeAll(bytes);
        alloc.free(bytes);
    }
    return self.parent.?;
}

/// Write to the **parent** context when the current context is popped.
pub fn deferLine(self: Self, bytes: []const u8) !void {
    const prefix = if (self.parent) |p| p.options.prefix else unreachable;
    var def_line = try self.ctxAllocator().alloc(u8, 1 + prefix.len + bytes.len);
    def_line[0] = '\n';
    @memcpy(def_line[1..][0..prefix.len], prefix);
    @memcpy(def_line[1 + prefix.len ..][0..bytes.len], bytes);
    try self.deferred.append(def_line);
}

test "deferLine" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    const writer = init(buffer.writer().any(), .{
        .prefix = "// ",
    });

    const scope = try writer.appendPrefix(test_alloc, "- ");
    try scope.deferLine("bar");
    try scope.prefixedAll("foo");
    _ = try scope.pop();

    try testing.expectEqualStrings("// - foo\n// bar", buffer.items);
}

/// Write to the **parent** context when the current context is popped.
pub fn deferLineFmt(self: Self, comptime format: []const u8, args: anytype) !void {
    const alloc = self.ctxAllocator();
    const prefix = if (self.parent) |p| p.options.prefix else unreachable;
    const line0 = try fmt.allocPrint(alloc, "\n{s}", .{prefix});
    errdefer alloc.free(line0);
    const line1 = try fmt.allocPrint(alloc, format, args);
    try self.deferred.ensureUnusedCapacity(2);
    self.deferred.appendAssumeCapacity(line0);
    self.deferred.appendAssumeCapacity(line1);
}

test "deferLineFmt" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    const writer = init(buffer.writer().any(), .{
        .prefix = "// ",
    });

    const scope = try writer.appendPrefix(test_alloc, "- ");
    try scope.deferLineFmt("{x}", .{16});
    try scope.prefixedAll("foo");
    _ = try scope.pop();

    try testing.expectEqualStrings("// - foo\n// 10", buffer.items);
}

fn ctxAllocator(self: Self) Allocator {
    assert(self.parent != null);
    return self.deferred.allocator;
}
