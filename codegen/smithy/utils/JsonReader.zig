const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const json = std.json;
const isIntegerFormat = json.isNumberFormattedLikeAnInteger;
const testing = std.testing;
const test_alloc = testing.allocator;

const Self = @This();
const Source = union(enum) {
    file: std.fs.File.Reader,
    fixed: struct {
        stream: std.io.FixedBufferStream([]const u8),
        reader: std.io.FixedBufferStream([]const u8).Reader,
    },

    fn deinit(self: *Source, allocator: Allocator) void {
        allocator.destroy(self);
    }
};

pub const Scope = enum { current, object, array };
pub const Number = union(enum) { integer: i64, float: f64 };

allocator: Allocator,
source: *Source,
scanner: json.Reader(json.default_buffer_size, std.io.AnyReader),

pub fn initFixed(allocator: Allocator, slice: []const u8) !Self {
    const source = try allocator.create(Source);
    source.* = .{ .fixed = .{
        .stream = std.io.fixedBufferStream(slice),
        .reader = undefined,
    } };
    const stream_reader = &source.fixed.reader;
    stream_reader.* = source.fixed.stream.reader();
    return .{
        .allocator = allocator,
        .source = source,
        .scanner = std.json.reader(allocator, stream_reader.any()),
    };
}

pub fn initFile(allocator: Allocator, file: std.fs.File) !Self {
    const source = try allocator.create(Source);
    source.* = .{ .file = file.reader() };
    return .{
        .allocator = allocator,
        .source = source,
        .scanner = std.json.reader(allocator, source.file.any()),
    };
}

pub fn deinit(self: *Self) void {
    self.scanner.deinit();
    self.source.deinit(self.allocator);
    self.* = undefined;
}

/// Get the next token’s type without consuming it.
pub fn peek(self: *Self) !json.TokenType {
    return try self.scanner.peekNextTokenType();
}

/// Consume the following token.
pub fn next(self: *Self) !json.Token {
    return try self.scanner.nextAlloc(self.allocator, .alloc_if_needed);
}

/// Get the next token, assuming it is an object.
pub fn nextObjectBegin(self: *Self) !void {
    const token = try self.next();
    if (token != .object_begin) return error.UnexpectedSyntax;
}

/// Get the next token, assuming it is the end of an object.
pub fn nextObjectEnd(self: *Self) !void {
    const token = try self.next();
    if (token != .object_end) return error.UnexpectedSyntax;
}

/// Get the next token, assuming it is an array.
pub fn nextArrayBegin(self: *Self) !void {
    const token = try self.next();
    if (token != .array_begin) return error.UnexpectedSyntax;
}

/// Get the next token, assuming it is the end of an array.
pub fn nextArrayEnd(self: *Self) !void {
    const token = try self.next();
    if (token != .array_end) return error.UnexpectedSyntax;
}

/// Get the next token, assuming it is the end of the document.
pub fn nextDocumentEnd(self: *Self) !void {
    const token = try self.next();
    if (token != .end_of_document) return error.UnexpectedSyntax;
}

/// Get the next token, assuming it is a null value.
pub fn nextNull(self: *Self) !void {
    const token = try self.next();
    if (token != .null) return error.UnexpectedSyntax;
}

/// Get the next token, assuming it is a boolean value.
pub fn nextBoolean(self: *Self) !bool {
    const token = try self.next();
    return switch (token) {
        .true => true,
        .false => false,
        else => error.UnexpectedSyntax,
    };
}

pub fn nextNumber(self: *Self) !Number {
    const token = try self.next();
    return switch (token) {
        .number, .allocated_number => |bytes| if (isIntegerFormat(bytes))
            .{ .integer = try std.fmt.parseInt(i64, bytes, 10) }
        else
            .{ .float = try std.fmt.parseFloat(f64, bytes) },
        .partial_number => unreachable, // Not used by `json.Reader`
        else => error.UnexpectedSyntax,
    };
}

/// Get the next token, assuming it is an integer value.
pub fn nextInteger(self: *Self) !i64 {
    const token = try self.next();
    return switch (token) {
        .number, .allocated_number => |bytes| if (isIntegerFormat(bytes))
            std.fmt.parseInt(i64, bytes, 10)
        else
            error.UnexpectedSyntax,
        .partial_number => unreachable, // Not used by `json.Reader`
        else => error.UnexpectedSyntax,
    };
}

/// Get the next token, assuming it is a float value.
pub fn nextFloat(self: *Self) !f64 {
    const token = try self.next();
    return switch (token) {
        .number, .allocated_number => |bytes| if (!isIntegerFormat(bytes))
            std.fmt.parseFloat(f64, bytes)
        else
            error.UnexpectedSyntax,
        .partial_number => unreachable, // Not used by `json.Reader`
        else => error.UnexpectedSyntax,
    };
}

/// Get the next token, assuming it is a string value.
pub fn nextString(self: *Self) ![]const u8 {
    const token = try self.next();
    return switch (token) {
        .string, .allocated_string => |s| s,
        .partial_string, .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4 => {
            unreachable; // Not used by `json.Reader`
        },
        else => error.UnexpectedSyntax,
    };
}

/// Get the next token, assuming it is a string matching the expected value.
pub fn nextStringEql(self: *Self, expectd: []const u8) !void {
    const actual = try self.nextString();
    if (!mem.eql(u8, expectd, actual)) return error.UnexpectedValue;
}

/// Assumes we already consumed the initial `*_begin`.
pub fn skipCurrentScope(self: *Self) !void {
    const current = self.scanner.stackHeight();
    if (current == 0) return error.UnexpectedSyntax;
    try self.scanner.skipUntilStackHeight(current -| 1);
}

/// Skips the following value, array, or object.
pub fn skipValueOrScope(self: *Self) !void {
    switch (try self.next()) {
        .object_begin, .array_begin => {
            const target = self.scanner.stackHeight() - 1;
            try self.scanner.skipUntilStackHeight(target);
        },
        else => {},
    }
}

pub fn NextScopeFn(Context: type, scope: Scope, Payload: type) type {
    return if (Payload == void) switch (scope) {
        .array => fn (ctx: Context) anyerror!void,
        .object, .current => fn (ctx: Context, key: []const u8) anyerror!void,
    } else switch (scope) {
        .array => fn (ctx: Context, payload: Payload) anyerror!void,
        .object, .current => fn (ctx: Context, key: []const u8, payload: Payload) anyerror!void,
    };
}

pub fn nextScope(
    self: *Self,
    Context: type,
    comptime scope: Scope,
    comptime Payload: type,
    comptime itemFn: NextScopeFn(Context, scope, Payload),
    ctx: Context,
    payload: Payload,
) !void {
    const is_void = comptime Payload == void;
    switch (scope) {
        inline .object, .current => |s| {
            const is_obj = s == .object;
            if (is_obj) try self.nextObjectBegin();
            while (try self.peek() == .string) {
                const key = try self.nextString();
                try if (is_void) itemFn(ctx, key) else itemFn(ctx, key, payload);
            }
            if (is_obj) try self.nextObjectEnd();
        },
        .array => {
            try self.nextArrayBegin();
            while (try self.peek() != .array_end) {
                try if (is_void) itemFn(ctx) else itemFn(ctx, payload);
            }
            try self.nextArrayEnd();
        },
    }
}

test "nextScope" {
    const TestFns = struct {
        pub var first: bool = true;

        pub fn nextObject(self: *Self, key: []const u8) !void {
            try testing.expectEqualStrings(if (first) "a" else "b", key);
            try testing.expectEqual(@as(i64, if (first) 108 else 109), self.nextInteger());
            first = false;
        }

        pub fn nextArray(self: *Self) !void {
            try testing.expectEqual(@as(i64, if (first) 108 else 109), self.nextInteger());
            first = false;
        }
    };

    var reader = try initFixed(test_alloc,
        \\{ "a": 108, "b": 109 }
    );
    errdefer reader.deinit();

    TestFns.first = true;
    try reader.nextScope(*Self, .object, void, TestFns.nextObject, &reader, {});
    reader.deinit();

    TestFns.first = true;
    reader = try initFixed(test_alloc, "[ 108, 109 ]");
    try reader.nextScope(*Self, .array, void, TestFns.nextArray, &reader, {});
    reader.deinit();
}

test "JsonReader" {
    var reader = try initFixed(test_alloc,
        \\{
        \\  "key": "val",
        \\  "int_pos": 108,
        \\  "int_neg": -108,
        \\  "flt": 1.08,
        \\  "num_a": 108,
        \\  "num_b": 1.08,
        \\  "arr": [null, true, false],
        \\  "obj": { "foo": "bar" },
        \\  "obj_nest": { "foo": { "bar": { "baz": "qux" } } },
        \\  "arr_nest": [ [ [ "foo" ] ] ],
        \\  "skip_any_a": {},
        \\  "skip_any_b": []
        \\}
    );
    defer reader.deinit();

    try testing.expectEqual(.object_begin, reader.peek());
    try testing.expectEqual(.object_begin, reader.next());

    try testing.expectEqualDeep(json.Token{ .string = "key" }, reader.next());
    try testing.expectEqualStrings("val", try reader.nextString());

    try reader.nextStringEql("int_pos");
    try testing.expectEqual(108, reader.nextInteger());
    try reader.nextStringEql("int_neg");
    try testing.expectEqual(-108, reader.nextInteger());
    try reader.nextStringEql("flt");
    try testing.expect(
        std.math.approxEqAbs(f64, 1.08, try reader.nextFloat(), std.math.floatEps(f64)),
    );

    try reader.nextStringEql("num_a");
    try testing.expectEqualDeep(Number{ .integer = 108 }, reader.nextNumber());

    try reader.nextStringEql("num_b");
    try testing.expectEqualDeep(Number{ .float = 1.08 }, reader.nextNumber());

    try reader.nextStringEql("arr");
    try reader.nextArrayBegin();
    try reader.nextNull();
    try testing.expectEqual(true, reader.nextBoolean());
    try testing.expectEqual(false, reader.nextBoolean());
    try reader.nextArrayEnd();

    try reader.nextStringEql("obj");
    try reader.nextObjectBegin();
    try reader.nextStringEql("foo");
    try reader.nextStringEql("bar");
    try reader.nextObjectEnd();

    try reader.nextStringEql("obj_nest");
    try reader.nextObjectBegin();
    try reader.skipCurrentScope();

    try reader.nextStringEql("arr_nest");
    try reader.nextArrayBegin();
    try reader.skipCurrentScope();

    try reader.skipValueOrScope();
    try reader.skipValueOrScope();
    try reader.skipValueOrScope();
    try reader.skipValueOrScope();

    try reader.nextObjectEnd();
    try reader.nextDocumentEnd();
}
