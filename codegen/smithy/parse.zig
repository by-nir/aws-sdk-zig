const std = @import("std");
const mem = std.mem;
const json = std.json;
const assert = std.debug.assert;
const testing = std.testing;
const test_alloc = testing.allocator;

pub const Stats = struct { shapes: usize, duration_ns: u64 };

pub const JsonReader = struct {
    arena: mem.Allocator,
    reader: *json.Reader(json.default_buffer_size, std.io.AnyReader),

    pub fn peek(self: JsonReader) !json.TokenType {
        return try self.reader.peekNextTokenType();
    }

    pub fn next(self: *JsonReader) !json.Token {
        return try self.reader.nextAlloc(self.arena, .alloc_if_needed);
    }

    pub fn nextObjectBegin(self: *JsonReader) !void {
        assert(.object_begin == try self.next());
    }

    pub fn nextObjectEnd(self: *JsonReader) !void {
        assert(.object_end == try self.next());
    }

    pub fn nextArrayBegin(self: *JsonReader) !void {
        assert(.array_begin == try self.next());
    }

    pub fn nextArrayEnd(self: *JsonReader) !void {
        assert(.array_end == try self.next());
    }

    pub fn nextDocumentEnd(self: *JsonReader) !void {
        assert(.end_of_document == try self.next());
    }

    pub fn nextNull(self: *JsonReader) !void {
        assert(.null == try self.next());
    }

    pub fn nextBool(self: *JsonReader) !bool {
        const token = try self.next();
        return switch (token) {
            .true => true,
            .false => false,
            else => unreachable,
        };
    }

    pub fn nextNumber(self: *JsonReader) !i64 {
        const token = try self.next();
        switch (token) {
            .number, .allocated_number => |bytes| {
                assert(json.isNumberFormattedLikeAnInteger(bytes));
                return std.fmt.parseInt(i64, bytes, 10);
            },
            .partial_number => unreachable, // Not used by `json.Reader`
            else => unreachable,
        }
    }

    pub fn nextFloat(self: *JsonReader) !f64 {
        const token = try self.next();
        switch (token) {
            .number, .allocated_number => |bytes| {
                assert(!json.isNumberFormattedLikeAnInteger(bytes));
                return std.fmt.parseFloat(f64, bytes);
            },
            .partial_number => unreachable, // Not used by `json.Reader`
            else => unreachable,
        }
    }

    pub fn nextString(self: *JsonReader) ![]const u8 {
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

    pub fn nextStringEql(self: *JsonReader, expectd: []const u8) !void {
        assert(mem.eql(u8, expectd, try self.nextString()));
    }

    /// Assumes we already consumed the initial `*_begin`.
    pub fn skipCurrentScope(self: *JsonReader) !void {
        const current = self.reader.stackHeight();
        assert(current > 0);
        try self.reader.skipUntilStackHeight(self.reader.stackHeight() - 1);
    }
};

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
        \\  "arr_nest": [ [ [ "foo" ] ] ]
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(test_alloc);
    defer arena.deinit();

    var stream = std.io.fixedBufferStream(input);
    var reader = std.json.reader(arena.allocator(), stream.reader().any());
    var parser = JsonReader{ .arena = arena.allocator(), .reader = &reader };

    try testing.expectEqual(.object_begin, parser.peek());
    try testing.expectEqual(.object_begin, parser.next());

    try testing.expectEqualDeep(json.Token{ .string = "key" }, parser.next());
    try testing.expectEqualStrings("val", try parser.nextString());

    try parser.nextStringEql("num_pos");
    try testing.expectEqual(108, parser.nextNumber());
    try parser.nextStringEql("num_neg");
    try testing.expectEqual(-108, parser.nextNumber());

    try parser.nextStringEql("num_flt");
    try testing.expect(std.math.approxEqAbs(f64, 1.08, try parser.nextFloat(), std.math.floatEps(f64)));

    try parser.nextStringEql("arr");
    try parser.nextArrayBegin();
    try parser.nextNull();
    try testing.expectEqual(true, parser.nextBool());
    try testing.expectEqual(false, parser.nextBool());
    try parser.nextArrayEnd();

    try parser.nextStringEql("obj");
    try parser.nextObjectBegin();
    try parser.nextStringEql("foo");
    try parser.nextStringEql("bar");
    try parser.nextObjectEnd();

    try parser.nextStringEql("obj_nest");
    try parser.nextObjectBegin();
    try parser.skipCurrentScope();

    try parser.nextStringEql("arr_nest");
    try parser.nextArrayBegin();
    try parser.skipCurrentScope();

    try parser.nextObjectEnd();
    try parser.nextDocumentEnd();
}
