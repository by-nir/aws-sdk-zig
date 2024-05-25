const std = @import("std");
const fmt = std.fmt;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;

const Self = @This();

allocator: Allocator,
output: std.io.AnyWriter,
prefix: []const u8 = "",
prefix_segments: std.ArrayListUnmanaged([]const u8) = .{},

pub fn init(allocator: Allocator, output: std.io.AnyWriter) Self {
    return .{
        .allocator = allocator,
        .output = output,
    };
}

pub fn initPrefix(allocator: Allocator, output: std.io.AnyWriter, prefix: []const u8) !Self {
    return .{
        .allocator = allocator,
        .output = output,
        .prefix = try allocator.dupe(u8, prefix),
    };
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.prefix);
    for (self.prefix_segments.items) |segment| {
        self.allocator.free(segment);
    }
    self.prefix_segments.deinit(self.allocator);
    self.* = undefined;
}

pub fn indent(self: *Self, segment: []const u8) !void {
    try self.prefix_segments.append(self.allocator, self.prefix);
    self.prefix = try fmt.allocPrint(self.allocator, "{s}{s}", .{ self.prefix, segment });
}

pub fn popIndent(self: *Self) void {
    self.allocator.free(self.prefix);
    self.prefix = self.prefix_segments.pop();
}

test "indent" {
    var writer = init(test_alloc, undefined);
    defer writer.deinit();

    try writer.indent("Foo");
    try testing.expectEqualStrings("Foo", writer.prefix);
    try writer.indent("Bar");
    try testing.expectEqualStrings("FooBar", writer.prefix);
    writer.popIndent();
    try testing.expectEqualStrings("Foo", writer.prefix);
    writer.popIndent();
    try testing.expectEqualStrings("", writer.prefix);
}

pub fn appendChar(self: *Self, char: u8) !void {
    try self.output.writeByte(char);
}

test "appendChar" {
    var buffer: [32]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    var writer = try initPrefix(test_alloc, stream.writer().any(), ">> ");
    defer writer.deinit();

    try writer.appendChar('a');
    try writer.appendChar('b');
    try testing.expectEqualStrings("ab", stream.getWritten());
}

pub fn appendStr(self: *Self, str: []const u8) !void {
    try self.output.writeAll(str);
}

test "appendStr" {
    var buffer: [32]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    var writer = try initPrefix(test_alloc, stream.writer().any(), ">> ");
    defer writer.deinit();

    try writer.appendStr("Foo");
    try writer.appendStr("Bar");
    try testing.expectEqualStrings("FooBar", stream.getWritten());
}

pub fn appendRepeatStr(self: *Self, n: usize, str: []const u8) !void {
    try self.output.writeBytesNTimes(str, n);
}

test "appendRepeatStr" {
    var buffer: [32]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    var writer = try initPrefix(test_alloc, stream.writer().any(), ">> ");
    defer writer.deinit();

    try writer.appendRepeatStr(2, "Foo");
    try writer.appendRepeatStr(2, "Bar");
    try testing.expectEqualStrings("FooFooBarBar", stream.getWritten());
}

pub fn appendPrefix(self: *Self) !void {
    try self.output.writeAll(self.prefix);
}

test "appendPrefix" {
    var buffer: [32]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    var writer = try initPrefix(test_alloc, stream.writer().any(), ">> ");
    defer writer.deinit();

    try writer.appendPrefix();
    try writer.appendPrefix();
    try testing.expectEqualStrings(">> >> ", stream.getWritten());
}

/// Expects a container type with method:
/// `pub fn write(self: T, writer: *CodegenWriter) !void`
pub fn appendValue(self: *Self, t: anytype) !void {
    try self.formatValue(t, "");
}

test "appendValue" {
    var buffer: [32]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    var writer = try initPrefix(test_alloc, stream.writer().any(), ">> ");
    defer writer.deinit();

    try writer.appendValue(TestWrite{ .value = "Foo" });
    try writer.appendValue(true);
    try testing.expectEqualStrings("Footrue", stream.getWritten());
}

/// The format string behaves similarly to `std.fmt`.
pub fn appendFmt(self: *Self, comptime format: []const u8, args: anytype) !void {
    try self.formatTemplate(format, args);
}

test "appendFmt" {
    var buffer: [32]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    var writer = try initPrefix(test_alloc, stream.writer().any(), ">> ");
    defer writer.deinit();

    try writer.appendFmt("1{}2{}3{s}", .{ TestWrite{ .value = "Foo" }, true, "Bar" });
    try testing.expectEqualStrings("1Foo2true3Bar", stream.getWritten());
}

pub fn breakChar(self: *Self, char: u8) !void {
    try self.output.print("\n{s}{c}", .{ self.prefix, char });
}

test "breakChar" {
    var buffer: [32]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    var writer = try initPrefix(test_alloc, stream.writer().any(), ">> ");
    defer writer.deinit();

    try writer.breakChar('a');
    try writer.breakChar('b');
    try testing.expectEqualStrings("\n>> a\n>> b", stream.getWritten());
}

pub fn breakStr(self: *Self, str: []const u8) !void {
    try self.output.print("\n{s}{s}", .{ self.prefix, str });
}

test "breakStr" {
    var buffer: [32]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    var writer = try initPrefix(test_alloc, stream.writer().any(), ">> ");
    defer writer.deinit();

    try writer.breakStr("Foo");
    try writer.breakStr("Bar");
    try testing.expectEqualStrings("\n>> Foo\n>> Bar", stream.getWritten());
}

pub fn breakRepeatStr(self: *Self, n: usize, str: []const u8) !void {
    try self.output.print("\n{s}", .{self.prefix});
    try self.output.writeBytesNTimes(str, n);
}

test "breakRepeatStr" {
    var buffer: [32]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    var writer = try initPrefix(test_alloc, stream.writer().any(), ">> ");
    defer writer.deinit();

    try writer.breakRepeatStr(2, "Foo");
    try writer.breakRepeatStr(2, "Bar");
    try testing.expectEqualStrings("\n>> FooFoo\n>> BarBar", stream.getWritten());
}

pub fn breakEmpty(self: *Self, n: usize) !void {
    const prefix = std.mem.trimRight(u8, self.prefix, &std.ascii.whitespace);
    for (0..n) |_| {
        try self.output.print("\n{s}", .{prefix});
    }
}

test "breakEmpty" {
    var buffer: [32]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    var writer = try initPrefix(test_alloc, stream.writer().any(), ">> ");
    defer writer.deinit();

    try writer.breakEmpty(2);
    try testing.expectEqualStrings("\n>>\n>>", stream.getWritten());
}

/// Expects a container type with method:
/// `pub fn write(self: T, writer: *CodegenWriter) !void`
pub fn breakValue(self: *Self, t: anytype) !void {
    try self.output.print("\n{s}", .{self.prefix});
    try self.formatValue(t, "");
}

test "breakValue" {
    var buffer: [32]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    var writer = try initPrefix(test_alloc, stream.writer().any(), ">> ");
    defer writer.deinit();

    try writer.breakValue(TestWrite{ .value = "Foo" });
    try writer.breakValue(true);
    try testing.expectEqualStrings("\n>> Foo\n>> true", stream.getWritten());
}

/// The format string behaves similarly to `std.fmt`.
pub fn breakFmt(self: *Self, comptime format: []const u8, args: anytype) !void {
    try self.output.print("\n{s}", .{self.prefix});
    try self.formatTemplate(format, args);
}

test "breakFmt" {
    var buffer: [32]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    var writer = try initPrefix(test_alloc, stream.writer().any(), ">> ");
    defer writer.deinit();

    try writer.breakFmt("1{}2{}3{s}", .{ TestWrite{ .value = "Foo" }, true, "Bar" });
    try testing.expectEqualStrings("\n>> 1Foo2true3Bar", stream.getWritten());
}

const MAX_DEPTH = std.options.fmt_max_depth;
fn formatValue(self: *Self, t: anytype, comptime format: []const u8) !void {
    const T = @TypeOf(t);
    if (std.meta.hasMethod(T, "write")) {
        try t.write(self);
    } else if (format.len == 0) {
        try fmt.formatType(t, format, .{}, self.output, MAX_DEPTH);
    } else {
        try self.output.print(format, .{t});
    }
}

// Based on std.fmt.format
fn formatTemplate(self: *Self, comptime format: []const u8, args: anytype) !void {
    const Args = @TypeOf(args);
    const args_meta = @typeInfo(Args);
    if (args_meta != .Struct) {
        @compileError("expected tuple or struct argument, found " ++ @typeName(Args));
    }

    const fields = args_meta.Struct.fields;
    if (fields.len > 32) {
        @compileError("32 arguments max are supported per format call");
    }

    @setEvalBranchQuota(2000000);
    comptime var i = 0;
    comptime var arg_index = 0;
    inline while (i < format.len) {
        const start_index = i;

        inline while (i < format.len) : (i += 1) {
            switch (format[i]) {
                '{', '}' => break,
                else => {},
            }
        }

        comptime var end_index = i;
        comptime var unescape_brace = false;

        // Handle {{ and }}, those are un-escaped as single braces
        if (i + 1 < format.len and format[i + 1] == format[i]) {
            unescape_brace = true;
            // Make the first brace part of the literal...
            end_index += 1;
            // ...and skip both
            i += 2;
        }

        // Write out the literal
        if (start_index != end_index) {
            try self.output.writeAll(format[start_index..end_index]);
        }

        // We've already skipped the other brace, restart the loop
        if (unescape_brace) continue;

        if (i >= format.len) break;

        if (format[i] == '}') {
            @compileError("missing opening {");
        }

        // Get past the {
        comptime std.debug.assert(format[i] == '{');
        const fmt_begin = i;
        i += 1;

        // Find the closing brace
        inline while (i < format.len and format[i] != '}') : (i += 1) {}

        if (i >= format.len) {
            @compileError("missing closing }");
        }

        // Get past the }
        comptime std.debug.assert(format[i] == '}');
        i += 1;
        const fmt_end = i;

        if (arg_index >= fields.len) {
            @compileError("too few arguments");
        }

        const value = @field(args, fields[arg_index].name);
        try self.formatValue(value, format[fmt_begin..fmt_end]);

        arg_index += 1;
    }

    if (arg_index == fields.len) return;

    const missing_count = fields.len - arg_index;
    switch (missing_count) {
        0 => unreachable,
        1 => @compileError("unused argument in '" ++ format ++ "'"),
        else => @compileError(
            fmt.comptimePrint("{d}", .{missing_count}) ++ " unused arguments in '" ++ format ++ "'",
        ),
    }
}

pub fn expect(expected: []const u8, t: anytype) !void {
    if (!std.meta.hasMethod(@TypeOf(t), "write")) {
        return error.MissingWriteMethod;
    }

    var list = std.ArrayList(u8).init(test_alloc);
    defer list.deinit();

    var writer = init(test_alloc, list.writer().any());
    defer writer.deinit();

    try writer.formatValue(t, "");
    try testing.expectEqualStrings(expected, list.items);
}

test "expect" {
    try expect("Foo", TestWrite{ .value = "Foo" });
    try testing.expectError(
        error.MissingWriteMethod,
        expect("", struct {}{}),
    );
}

const TestWrite = struct {
    value: []const u8,

    pub fn write(self: TestWrite, writer: *Self) !void {
        try writer.appendStr(self.value);
    }
};