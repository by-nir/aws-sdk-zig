const std = @import("std");
const json = std.json;
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;

const Self = @This();

allocator: Allocator,
source: json.Reader(json.default_buffer_size, std.io.AnyReader),

pub fn init(allocator: Allocator, source: std.io.AnyReader) Self {
    return .{
        .allocator = allocator,
        .source = std.json.reader(allocator, source),
    };
}

pub fn deinit(self: *Self) void {
    self.source.deinit();
    self.* = undefined;
}

/// Get the next token’s type without consuming it.
pub fn peek(self: *Self) !json.TokenType {
    return try self.source.peekNextTokenType();
}

/// Consume the following token.
pub fn next(self: *Self) !json.Token {
    return try self.source.nextAlloc(self.allocator, .alloc_if_needed);
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
pub fn nextBool(self: *Self) !bool {
    const token = try self.next();
    return switch (token) {
        .true => true,
        .false => false,
        else => unreachable,
    };
}

/// Get the next token, assuming it is an integer value.
pub fn nextNumber(self: *Self) !i64 {
    const token = try self.next();
    switch (token) {
        .number, .allocated_number => |bytes| {
            std.debug.assert(json.isNumberFormattedLikeAnInteger(bytes));
            return std.fmt.parseInt(i64, bytes, 10);
        },
        .partial_number => unreachable, // Not used by `json.Reader`
        else => unreachable,
    }
}

/// Get the next token, assuming it is a float value.
pub fn nextFloat(self: *Self) !f64 {
    const token = try self.next();
    switch (token) {
        .number, .allocated_number => |bytes| {
            std.debug.assert(!json.isNumberFormattedLikeAnInteger(bytes));
            return std.fmt.parseFloat(f64, bytes);
        },
        .partial_number => unreachable, // Not used by `json.Reader`
        else => unreachable,
    }
}

/// Get the next token, assuming it is a string value.
pub fn nextString(self: *Self) ![]const u8 {
    const token = try self.next();
    return switch (token) {
        .string, .allocated_string => |s| s,
        .partial_string, .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4 => {
            // Not used by `json.Reader`
            unreachable;
        },
        else => unreachable,
    };
}

/// Get the next token, assuming it is a string matching the expected value.
pub fn nextStringEql(self: *Self, expectd: []const u8) !void {
    const actual = try self.nextString();
    if (!mem.eql(u8, expectd, actual)) return error.UnexpectedValue;
}

/// Assumes we already consumed the initial `*_begin`.
pub fn skipCurrentScope(self: *Self) !void {
    const current = self.source.stackHeight();
    std.debug.assert(current > 0);
    try self.source.skipUntilStackHeight(current -| 1);
}

/// Skips the following value, array, or object.
pub fn skipValueOrScope(self: *Self) !void {
    switch (try self.next()) {
        .object_begin, .array_begin => {
            const target = self.source.stackHeight() - 1;
            try self.source.skipUntilStackHeight(target);
        },
        else => {},
    }
}

test "JsonReader" {
    const input: []const u8 =
        \\{
        \\  "key": "val",
        \\  "num_pos": 108,
        \\  "num_neg": -108,
        \\  "num_flt": 1.08,
        \\  "arr": [null, true, false],
        \\  "obj": { "foo": "bar" },
        \\  "obj_nest": { "foo": { "bar": { "baz": "qux" } } },
        \\  "arr_nest": [ [ [ "foo" ] ] ],
        \\  "skip_any_a": {},
        \\  "skip_any_b": []
        \\}
    ;

    var stream = std.io.fixedBufferStream(input);
    var reader = init(test_alloc, stream.reader().any());
    defer reader.deinit();

    try testing.expectEqual(.object_begin, reader.peek());
    try testing.expectEqual(.object_begin, reader.next());

    try testing.expectEqualDeep(json.Token{ .string = "key" }, reader.next());
    try testing.expectEqualStrings("val", try reader.nextString());

    try reader.nextStringEql("num_pos");
    try testing.expectEqual(108, reader.nextNumber());
    try reader.nextStringEql("num_neg");
    try testing.expectEqual(-108, reader.nextNumber());

    try reader.nextStringEql("num_flt");
    try testing.expect(std.math.approxEqAbs(f64, 1.08, try reader.nextFloat(), std.math.floatEps(f64)));

    try reader.nextStringEql("arr");
    try reader.nextArrayBegin();
    try reader.nextNull();
    try testing.expectEqual(true, reader.nextBool());
    try testing.expectEqual(false, reader.nextBool());
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
