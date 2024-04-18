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

pub const DeferTarget = enum { self, parent };
const Deferred = struct {
    bytes: []const u8,
    target: DeferTarget,
};

allocator: Allocator,
options: Options,
output: std.io.AnyWriter,
deferred: std.ArrayListUnmanaged(Deferred) = .{},
parent: ?*Self = null,

pub fn init(allocator: Allocator, output: std.io.AnyWriter, options: Options) Self {
    return .{
        .allocator = allocator,
        .output = output,
        .options = options,
    };
}

fn initContext(self: *Self, prefix: []const u8) !*Self {
    var context = try self.allocator.create(Self);
    context.* = .{
        .allocator = self.allocator,
        .output = self.output,
        .options = self.options,
        .parent = self,
    };
    context.options.prefix = prefix;
    return context;
}

/// Returns a new sub-writer with the replacement prefix.
pub fn replacePrefix(self: *Self, prefix: []const u8) !*Self {
    const new_prefix = try self.allocator.alloc(u8, prefix.len);
    @memcpy(new_prefix, prefix);
    return self.initContext(new_prefix);
}

/// Returns a new sub-writer with the extended prefix.
pub fn appendPrefix(self: *Self, append: []const u8) !*Self {
    const old_prefix = self.options.prefix;
    if (append.len == 0) {
        return self.initContext(old_prefix);
    } else {
        var new_prefix = try self.allocator.alloc(u8, old_prefix.len + append.len);
        @memcpy(new_prefix[0..old_prefix.len], old_prefix);
        @memcpy(new_prefix[old_prefix.len..][0..append.len], append);
        return self.initContext(new_prefix);
    }
}

/// Returns the parent context.
pub fn deinit(self: *Self) !void {
    defer if (self.parent) |parent| {
        if (!std.mem.eql(u8, parent.options.prefix, self.options.prefix)) {
            self.allocator.free(self.options.prefix);
        }
        self.allocator.destroy(self);
    };
    try self.consumeDeferred();
}

fn consumeDeferred(self: *Self) !void {
    var parent_cnt: usize = 0;
    var parent_idx: [16]usize = undefined;
    for (self.deferred.items, 0..) |line, i| switch (line.target) {
        .self => {
            try self.output.writeAll(line.bytes);
            self.allocator.free(line.bytes);
        },
        .parent => {
            if (parent_cnt < parent_idx.len) {
                parent_idx[parent_cnt] = i;
                parent_cnt += 1;
            } else {
                // Note that deferLineFmt consumes as 2 lines.
                return error.ParentDeferredOverflow;
            }
        },
    };

    for (0..parent_cnt) |i| {
        const idx = parent_idx[i];
        const line = self.deferred.items[idx];
        try self.output.writeAll(line.bytes);
        self.allocator.free(line.bytes);
    }

    self.deferred.deinit(self.allocator);
}

pub fn writeByte(self: *Self, byte: u8) !void {
    try self.output.writeByte(byte);
}

test "writeByte" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var writer = init(test_alloc, buffer.writer().any(), .{});
    try writer.writeByte('f');
    try writer.deinit();
    try testing.expectEqualStrings("f", buffer.items);
}

pub fn writeNByte(self: *Self, byte: u8, n: usize) !void {
    try self.output.writeByteNTimes(byte, n);
}

test "writeNByte" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var writer = init(test_alloc, buffer.writer().any(), .{});
    try writer.writeNByte('x', 3);
    try writer.deinit();
    try testing.expectEqualStrings("xxx", buffer.items);
}

pub fn writeAll(self: *Self, bytes: []const u8) !void {
    try self.output.writeAll(bytes);
}

test "writeAll" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var writer = init(test_alloc, buffer.writer().any(), .{});
    try writer.writeAll("foo");
    try writer.deinit();
    try testing.expectEqualStrings("foo", buffer.items);
}

pub fn writeFmt(self: *Self, comptime format: []const u8, args: anytype) !void {
    try self.output.print(format, args);
}

test "writeFmt" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var writer = init(test_alloc, buffer.writer().any(), .{
        .prefix = "  ",
    });
    try writer.writeFmt("{x}", .{16});
    try writer.deinit();
    try testing.expectEqualStrings("10", buffer.items);
}

pub fn prefixedAll(self: *Self, bytes: []const u8) !void {
    try self.output.print("{s}{s}", .{ self.options.prefix, bytes });
}

test "prefixedAll" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var writer = init(test_alloc, buffer.writer().any(), .{
        .prefix = "  ",
    });
    try writer.prefixedAll("foo");
    try writer.deinit();
    try testing.expectEqualStrings("  foo", buffer.items);
}

pub fn prefixedFmt(self: *Self, comptime format: []const u8, args: anytype) !void {
    try self.output.print("{s}", .{self.options.prefix});
    try self.output.print(format, args);
}

test "prefixedFmt" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var writer = init(test_alloc, buffer.writer().any(), .{
        .prefix = "  ",
    });
    try writer.prefixedFmt("{x}", .{16});
    try writer.deinit();
    try testing.expectEqualStrings("  10", buffer.items);
}

pub fn lineAll(self: *Self, bytes: []const u8) !void {
    try self.output.print("\n{s}{s}", .{ self.options.prefix, bytes });
}

test "lineAll" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var writer = init(test_alloc, buffer.writer().any(), .{
        .prefix = "  ",
    });
    try writer.lineAll("foo");
    try writer.deinit();
    try testing.expectEqualStrings("\n  foo", buffer.items);
}

pub fn lineFmt(self: *Self, comptime format: []const u8, args: anytype) !void {
    try self.output.print("\n{s}", .{self.options.prefix});
    try self.output.print(format, args);
}

test "lineFmt" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var writer = init(test_alloc, buffer.writer().any(), .{
        .prefix = "  ",
    });
    try writer.lineFmt("{x}", .{16});
    try writer.deinit();
    try testing.expectEqualStrings("\n  10", buffer.items);
}

pub fn lineBreak(self: *Self, n: u8) !void {
    for (0..n) |_| {
        try self.output.print("\n{s}", .{self.options.prefix});
    }
}

test "lineBreak" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var writer = init(test_alloc, buffer.writer().any(), .{
        .prefix = "  ",
    });
    try writer.lineBreak(2);
    try writer.deinit();
    try testing.expectEqualStrings("\n  \n  ", buffer.items);
}

/// Defer writing the line until this context is deinitialized.
pub fn deferLineAll(self: *Self, target: DeferTarget, bytes: []const u8) !void {
    const prefix = switch (target) {
        .self => self.options.prefix,
        .parent => self.parent.?.options.prefix,
    };
    var line = try self.allocator.alloc(u8, 1 + prefix.len + bytes.len);
    line[0] = '\n';
    @memcpy(line[1..][0..prefix.len], prefix);
    @memcpy(line[1 + prefix.len ..][0..bytes.len], bytes);
    try self.deferred.append(self.allocator, Deferred{
        .bytes = line,
        .target = target,
    });
}

test "deferLineAll" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var writer = init(test_alloc, buffer.writer().any(), .{
        .prefix = "// ",
    });
    try writer.prefixedAll("foo");

    const scope = try writer.appendPrefix("- ");
    try scope.deferLineAll(.parent, "qux");
    try scope.deferLineAll(.self, "baz");
    try scope.lineAll("bar");
    try scope.deinit();

    try writer.deinit();
    try testing.expectEqualStrings(
        \\// foo
        \\// - bar
        \\// - baz
        \\// qux
    , buffer.items);
}

/// Defer writing the line until this context is deinitialized.
pub fn deferLineFmt(self: *Self, target: DeferTarget, comptime format: []const u8, args: anytype) !void {
    const prefix = switch (target) {
        .self => self.options.prefix,
        .parent => self.parent.?.options.prefix,
    };
    const line0 = Deferred{
        .bytes = try fmt.allocPrint(self.allocator, "\n{s}", .{prefix}),
        .target = target,
    };
    errdefer self.allocator.free(line0.bytes);
    const line1 = Deferred{
        .bytes = try fmt.allocPrint(self.allocator, format, args),
        .target = target,
    };
    try self.deferred.appendSlice(self.allocator, &.{ line0, line1 });
}

test "deferLineFmt" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var writer = init(test_alloc, buffer.writer().any(), .{
        .prefix = "// ",
    });
    try writer.prefixedAll("0x8");

    const scope = try writer.appendPrefix("- ");
    try scope.deferLineFmt(.parent, "0x{X}", .{17});
    try scope.deferLineFmt(.self, "0x{X}", .{16});
    try scope.lineAll("0x9");
    try scope.deinit();

    try writer.deinit();
    try testing.expectEqualStrings(
        \\// 0x8
        \\// - 0x9
        \\// - 0x10
        \\// 0x11
    , buffer.items);
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
