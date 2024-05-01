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
    line_prefix: []const u8 = "",
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
    context.options.line_prefix = prefix;
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
    const old_prefix = self.options.line_prefix;
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
        if (!std.mem.eql(u8, parent.options.line_prefix, self.options.line_prefix)) {
            self.allocator.free(self.options.line_prefix);
        }
        self.allocator.destroy(self);
    };
    try self.applyDeferred();
}

pub fn applyDeferred(self: *Self) !void {
    var parent_cnt: usize = 0;
    var parent_idx: [16]usize = undefined;

    var prfx = std.mem.trimRight(u8, self.options.line_prefix, " ");
    for (self.deferred.items, 0..) |line, i| {
        switch (line.target) {
            .self => {
                if (line.bytes.ptr == LINE_BREAK.ptr) {
                    try self.output.print("\n{s}", .{prfx});
                } else {
                    try self.output.writeAll(line.bytes);
                    self.allocator.free(line.bytes);
                }
            },
            .parent => {
                if (parent_cnt < parent_idx.len) {
                    parent_idx[parent_cnt] = i;
                    parent_cnt += 1;
                } else {
                    return error.ParentDeferredOverflow;
                }
            },
        }
    }

    if (parent_cnt > 0) {
        prfx = std.mem.trimRight(u8, self.parent.?.options.line_prefix, " ");
        for (0..parent_cnt) |i| {
            const idx = parent_idx[i];
            const line = self.deferred.items[idx];
            if (line.bytes.ptr == LINE_BREAK.ptr) {
                try self.output.print("\n{s}", .{prfx});
            } else {
                try self.output.writeAll(line.bytes);
                self.allocator.free(line.bytes);
            }
        }
    }

    self.deferred.clearAndFree(self.allocator);
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
        .line_prefix = "  ",
    });
    try writer.writeFmt("{x}", .{16});
    try writer.deinit();
    try testing.expectEqualStrings("10", buffer.items);
}

pub fn writePrefix(self: *Self) !void {
    try self.output.writeAll(self.options.line_prefix);
}

test "writePrefix" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var writer = init(test_alloc, buffer.writer().any(), .{
        .line_prefix = "//",
    });
    try writer.writePrefix();
    try writer.deinit();
    try testing.expectEqualStrings("//", buffer.items);
}

pub fn prefixedAll(self: *Self, bytes: []const u8) !void {
    try self.output.print("{s}{s}", .{ self.options.line_prefix, bytes });
}

test "prefixedAll" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var writer = init(test_alloc, buffer.writer().any(), .{
        .line_prefix = "  ",
    });
    try writer.prefixedAll("foo");
    try writer.deinit();
    try testing.expectEqualStrings("  foo", buffer.items);
}

pub fn prefixedFmt(self: *Self, comptime format: []const u8, args: anytype) !void {
    try self.output.print("{s}", .{self.options.line_prefix});
    try self.output.print(format, args);
}

test "prefixedFmt" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var writer = init(test_alloc, buffer.writer().any(), .{
        .line_prefix = "  ",
    });
    try writer.prefixedFmt("{x}", .{16});
    try writer.deinit();
    try testing.expectEqualStrings("  10", buffer.items);
}

pub fn lineAll(self: *Self, bytes: []const u8) !void {
    try self.output.print("\n{s}{s}", .{ self.options.line_prefix, bytes });
}

test "lineAll" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var writer = init(test_alloc, buffer.writer().any(), .{
        .line_prefix = "  ",
    });
    try writer.lineAll("foo");
    try writer.deinit();
    try testing.expectEqualStrings("\n  foo", buffer.items);
}

pub fn lineFmt(self: *Self, comptime format: []const u8, args: anytype) !void {
    try self.output.print("\n{s}", .{self.options.line_prefix});
    try self.output.print(format, args);
}

test "lineFmt" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var writer = init(test_alloc, buffer.writer().any(), .{
        .line_prefix = "  ",
    });
    try writer.lineFmt("{x}", .{16});
    try writer.deinit();
    try testing.expectEqualStrings("\n  10", buffer.items);
}

pub fn lineBreak(self: *Self, n: u8) !void {
    assert(n > 0);
    if (n > 1) {
        const trimmed = std.mem.trimRight(u8, self.options.line_prefix, " ");
        for (0..n - 1) |_| {
            try self.output.print("\n{s}", .{trimmed});
        }
    }
    try self.output.print("\n{s}", .{self.options.line_prefix});
}

test "lineBreak" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var writer = init(test_alloc, buffer.writer().any(), .{
        .line_prefix = "//  ",
    });
    try writer.lineBreak(2);
    try writer.deinit();
    try testing.expectEqualStrings("\n//\n//  ", buffer.items);
}

/// Defer writing until this context is deinitialized.
pub fn deferAll(self: *Self, target: DeferTarget, bytes: []const u8) !void {
    const line = try self.allocator.dupe(u8, bytes);
    try self.deferred.append(self.allocator, Deferred{
        .bytes = line,
        .target = target,
    });
}

test "deferAll" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var writer = init(test_alloc, buffer.writer().any(), .{
        .line_prefix = "// ",
    });
    try writer.prefixedAll("foo");

    const scope = try writer.appendPrefix("- ");
    try scope.deferAll(.parent, ", qux");
    try scope.deferAll(.self, ", baz");
    try scope.writeAll(", bar");
    try scope.deinit();

    try writer.deinit();
    try testing.expectEqualStrings("// foo, bar, baz, qux", buffer.items);
}

/// Defer writing until this context is deinitialized.
pub fn deferFmt(self: *Self, target: DeferTarget, comptime format: []const u8, args: anytype) !void {
    const line = try fmt.allocPrint(self.allocator, format, args);
    try self.deferred.append(self.allocator, Deferred{
        .bytes = line,
        .target = target,
    });
}

test "deferFmt" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var writer = init(test_alloc, buffer.writer().any(), .{
        .line_prefix = "// ",
    });
    try writer.prefixedAll("0x8");

    const scope = try writer.appendPrefix("- ");
    try scope.deferFmt(.parent, ", 0x{X}", .{17});
    try scope.deferFmt(.self, ", 0x{X}", .{16});
    try scope.writeAll(", 0x9");
    try scope.deinit();

    try writer.deinit();
    try testing.expectEqualStrings("// 0x8, 0x9, 0x10, 0x11", buffer.items);
}

/// Defer writing the line until this context is deinitialized.
const LINE_BREAK: []const u8 = "";
pub fn deferLineBreak(self: *Self, target: DeferTarget, n: u8) !void {
    for (0..n) |_| {
        try self.deferred.append(self.allocator, Deferred{
            .bytes = LINE_BREAK,
            .target = target,
        });
    }
}

test "deferLineBreak" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var writer = init(test_alloc, buffer.writer().any(), .{
        .line_prefix = "// ",
    });
    try writer.prefixedAll("foo");

    const scope = try writer.appendPrefix("- ");
    try scope.deferLineBreak(.parent, 2);
    try scope.deferLineBreak(.self, 2);
    try scope.lineAll("bar");
    try scope.deinit();

    try writer.deinit();
    try testing.expectEqualStrings(
        \\// foo
        \\// - bar
        \\// -
        \\// -
        \\//
        \\//
    , buffer.items);
}

/// Defer writing the line until this context is deinitialized.
pub fn deferLineAll(self: *Self, target: DeferTarget, bytes: []const u8) !void {
    const prefix = switch (target) {
        .self => self.options.line_prefix,
        .parent => self.parent.?.options.line_prefix,
    };
    const line = try fmt.allocPrint(self.allocator, "\n{s}{s}", .{ prefix, bytes });
    try self.deferred.append(self.allocator, Deferred{
        .bytes = line,
        .target = target,
    });
}

test "deferLineAll" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var writer = init(test_alloc, buffer.writer().any(), .{
        .line_prefix = "// ",
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
        .self => self.options.line_prefix,
        .parent => self.parent.?.options.line_prefix,
    };

    const len_user = fmt.count(format, args);
    var line = try self.allocator.alloc(u8, 1 + prefix.len + len_user);
    errdefer self.allocator.free(line);
    line[0] = '\n';
    @memcpy(line[1..][0..prefix.len], prefix);
    _ = try fmt.bufPrint(line[1 + prefix.len ..], format, args);
    try self.deferred.append(
        self.allocator,
        .{ .bytes = line, .target = target },
    );
}

test "deferLineFmt" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var writer = init(test_alloc, buffer.writer().any(), .{
        .line_prefix = "// ",
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
