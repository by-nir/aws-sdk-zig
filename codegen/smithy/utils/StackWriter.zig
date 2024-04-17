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

allocator: Allocator,
options: Options,
output: std.io.AnyWriter,
parent: ?*const Self = null,
deferred: *std.ArrayListUnmanaged([]const u8) = undefined,

pub fn init(allocator: Allocator, output: std.io.AnyWriter, options: Options) Self {
    return .{
        .allocator = allocator,
        .output = output,
        .options = options,
    };
}

/// Returns a new writer context with the replacement prefix.
/// Call `popPrefix()` to restore the previous context.
pub fn replacePrefix(self: *const Self, prefix: []const u8) !*const Self {
    const new_prefix = try self.allocator.alloc(u8, prefix.len);
    @memcpy(new_prefix, prefix);
    return self.push(new_prefix);
}

/// Returns a new writer context with the extended prefix.
/// Call `popPrefix()` to restore the previous context.
pub fn appendPrefix(self: *const Self, append: []const u8) !*const Self {
    const alloc = self.allocator;
    const old_prefix = self.options.prefix;
    if (append.len == 0) {
        return self.push(old_prefix);
    } else {
        var new_prefix = try alloc.alloc(u8, old_prefix.len + append.len);
        @memcpy(new_prefix[0..old_prefix.len], old_prefix);
        @memcpy(new_prefix[old_prefix.len..][0..append.len], append);
        return self.push(new_prefix);
    }
}

fn push(self: *const Self, prefix: []const u8) !*const Self {
    const alloc = self.allocator;
    var context = try alloc.create(Self);
    context.* = .{
        .allocator = alloc,
        .output = self.output,
        .options = self.options,
        .parent = self,
        .deferred = try alloc.create(std.ArrayListUnmanaged([]const u8)),
    };
    context.options.prefix = prefix;
    context.deferred.* = .{};
    return context;
}

/// Restores the previous prefix context and writes the deferred lines to it.
pub fn pop(self: *const Self) !*const Self {
    const alloc = self.allocator;
    const parent = self.parent orelse unreachable;
    defer {
        if (!std.mem.eql(u8, parent.options.prefix, self.options.prefix)) {
            alloc.free(self.options.prefix);
        }

        self.deferred.deinit(alloc);
        alloc.destroy(self.deferred);
        alloc.destroy(self);
    }
    for (self.deferred.items) |bytes| {
        try self.output.writeAll(bytes);
        alloc.free(bytes);
    }
    return parent;
}

pub fn writeByte(self: Self, byte: u8) !void {
    try self.output.writeByte(byte);
}

test "writeByte" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    const writer = init(test_alloc, buffer.writer().any(), .{});
    try writer.writeByte('f');
    try testing.expectEqualStrings("f", buffer.items);
}

pub fn writeNByte(self: Self, byte: u8, n: usize) !void {
    try self.output.writeByteNTimes(byte, n);
}

test "writeNByte" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    const writer = init(test_alloc, buffer.writer().any(), .{});
    try writer.writeNByte('x', 3);
    try testing.expectEqualStrings("xxx", buffer.items);
}

pub fn writeAll(self: Self, bytes: []const u8) !void {
    try self.output.writeAll(bytes);
}

test "writeAll" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    const writer = init(test_alloc, buffer.writer().any(), .{});
    try writer.writeAll("foo");
    try testing.expectEqualStrings("foo", buffer.items);
}

pub fn writeFmt(self: Self, comptime format: []const u8, args: anytype) !void {
    try self.output.print(format, args);
}

test "writeFmt" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    const writer = init(test_alloc, buffer.writer().any(), .{
        .prefix = "  ",
    });
    try writer.writeFmt("{x}", .{16});
    try testing.expectEqualStrings("10", buffer.items);
}

pub fn prefixedAll(self: Self, bytes: []const u8) !void {
    try self.output.print("{s}{s}", .{ self.options.prefix, bytes });
}

test "prefixedAll" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    const writer = init(test_alloc, buffer.writer().any(), .{
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

    const writer = init(test_alloc, buffer.writer().any(), .{
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

    const writer = init(test_alloc, buffer.writer().any(), .{
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

    const writer = init(test_alloc, buffer.writer().any(), .{
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

    const writer = init(test_alloc, buffer.writer().any(), .{
        .prefix = "  ",
    });
    try writer.lineBreak();
    try testing.expectEqualStrings("\n  ", buffer.items);
}

/// Write to the **parent** context when the current context is popped.
pub fn deferLineAll(self: Self, bytes: []const u8) !void {
    const prefix = if (self.parent) |p| p.options.prefix else unreachable;
    var def_line = try self.allocator.alloc(u8, 1 + prefix.len + bytes.len);
    def_line[0] = '\n';
    @memcpy(def_line[1..][0..prefix.len], prefix);
    @memcpy(def_line[1 + prefix.len ..][0..bytes.len], bytes);
    try self.deferred.append(self.allocator, def_line);
}

test "deferLineAll" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    const writer = init(test_alloc, buffer.writer().any(), .{
        .prefix = "// ",
    });

    const scope = try writer.appendPrefix("- ");
    try scope.deferLineAll("bar");
    try scope.prefixedAll("foo");
    _ = try scope.pop();

    try testing.expectEqualStrings("// - foo\n// bar", buffer.items);
}

/// Write to the **parent** context when the current context is popped.
pub fn deferLineFmt(self: Self, comptime format: []const u8, args: anytype) !void {
    const prefix = if (self.parent) |p| p.options.prefix else unreachable;
    const line0 = try fmt.allocPrint(self.allocator, "\n{s}", .{prefix});
    errdefer self.allocator.free(line0);
    const line1 = try fmt.allocPrint(self.allocator, format, args);
    try self.deferred.ensureUnusedCapacity(self.allocator, 2);
    self.deferred.appendAssumeCapacity(line0);
    self.deferred.appendAssumeCapacity(line1);
}

test "deferLineFmt" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    const writer = init(test_alloc, buffer.writer().any(), .{
        .prefix = "// ",
    });

    const scope = try writer.appendPrefix("- ");
    try scope.deferLineFmt("{x}", .{16});
    try scope.prefixedAll("foo");
    _ = try scope.pop();

    try testing.expectEqualStrings("// - foo\n// 10", buffer.items);
}

pub const ListPadding = union(enum) {
    none,
    both: []const u8,
    sides: [2][]const u8,
};

pub fn List(comptime T: type) type {
    return struct {
        items: []const T,
        delimiter: []const u8 = ", ",
        padding: ListPadding = .none,
        /// Alternative padding to apply when only one item exists.
        padding_single: ?ListPadding = null,

        pub fn format(self: @This(), comptime item_fmt: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
            const padding = self.getPadding();
            try writePadding(padding, writer, false);
            for (self.items, 0..) |item, i| {
                if (i > 0) {
                    try writer.print("{s}{" ++ item_fmt ++ "}", .{ self.delimiter, item });
                } else {
                    const depth = fmt.default_max_depth - 1;
                    try fmt.formatType(item, item_fmt, .{}, writer, depth);
                }
            }
            try writePadding(padding, writer, true);
        }

        fn getPadding(self: @This()) ListPadding {
            if (self.padding_single == null or self.items.len > 1) {
                return self.padding;
            } else {
                return self.padding_single.?;
            }
        }

        fn writePadding(padding: ListPadding, writer: anytype, end: bool) !void {
            switch (padding) {
                .none => {},
                .both => |s| try writer.writeAll(s),
                .sides => |s| try writer.writeAll(s[if (end) 1 else 0]),
            }
        }
    };
}

test "List" {
    try testing.expectFmt("foo, bar, baz", "{s}", .{List([]const u8){
        .items = &.{ "foo", "bar", "baz" },
    }});

    try testing.expectFmt("|foo, bar, baz|", "{s}", .{List([]const u8){
        .items = &.{ "foo", "bar", "baz" },
        .padding = .{ .both = "|" },
    }});

    try testing.expectFmt(".{ foo, bar, baz }", "{s}", .{List([]const u8){
        .items = &.{ "foo", "bar", "baz" },
        .padding = .{ .sides = [_][]const u8{ ".{ ", " }" } },
        .padding_single = .{ .sides = [_][]const u8{ ".{", "}" } },
    }});

    try testing.expectFmt(".{foo}", "{s}", .{List([]const u8){
        .items = &.{"foo"},
        .padding = .{ .sides = [_][]const u8{ ".{ ", " }" } },
        .padding_single = .{ .sides = [_][]const u8{ ".{", "}" } },
    }});
}
