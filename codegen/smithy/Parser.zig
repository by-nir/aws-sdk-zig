//! Smithy parser for [JSON AST](https://smithy.io/2.0/spec/json-ast.html) representation.
const std = @import("std");
const json = std.json;
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const assert = std.debug.assert;
const util_shapes = @import("shapes.zig");
const Model = util_shapes.Model;
const ShapeId = util_shapes.ShapeId;
const SmithyType = util_shapes.SmithyType;

const Self = @This();

allocator: Allocator,
reader: Reader,
shapes: std.AutoHashMapUnmanaged(ShapeId, SmithyType) = .{},

/// Parse raw JSON into collection of annotated shapes.
///
/// `input_arena` is a beffur used to read JSON input, it should be disposed immediately after parsing.
/// `output_alloc` is used to allocate the output parse model, it must be retained as long as it is needed.
pub fn parseJsonModel(input_arena: Allocator, output_alloc: Allocator, reader: std.io.AnyReader) !Model {
    var parser = Self{
        .allocator = output_alloc,
        .reader = Reader.init(input_arena, reader),
    };

    try parser.reader.nextObjectBegin();
    try parser.assertSmithy();

    while (try parser.reader.peek() == .string) {
        const section = try parser.reader.nextString();
        if (mem.eql(u8, "shapes", section)) {
            try parser.reader.nextObjectBegin();
            try parser.parseShapes();
            try parser.reader.nextObjectEnd();
        } else {
            std.log.warn("Unknown model section: `{s}`.", .{section});
            try parser.reader.skipValueOrScope();
        }
    }

    try parser.reader.nextObjectEnd();
    try parser.reader.nextDocumentEnd();

    return Model{
        .shapes = parser.shapes.move(),
    };
}

fn assertSmithy(self: *Self) !void {
    try self.reader.nextStringEql("smithy");
    try self.reader.nextStringEql("2.0");
}

fn parseShapes(self: *Self) !void {
    while (try self.reader.peek() == .string) {
        const shape_id = try self.reader.nextString();
        const shape_hash = ShapeId.full(shape_id);
        try self.reader.nextObjectBegin();
        try self.reader.nextStringEql("type");
        const shape_type = ShapeId.full(try self.reader.nextString());

        var members: std.ArrayListUnmanaged(ShapeId) = .{};
        while (try self.reader.peek() == .string) {
            const section = try self.reader.nextString();
            try self.reader.nextObjectBegin();
            if (mem.eql(u8, "members", section)) {
                while (try self.reader.peek() == .string) {
                    try self.parseMember(shape_id, &members);
                }
            } else if (mem.eql(u8, "traits", section)) {
                try self.reader.skipCurrentScope();
                continue;
            } else {
                // We assume other sections are direct members (list memeber, map k/v, etc.)
                try self.reader.nextStringEql("target");
                const member_type = ShapeId.full(try self.reader.nextString());
                const member_id = ShapeId.compose(shape_id, section);
                try members.append(self.allocator, member_id);
                try self.putShape(member_id, member_type, null);
            }
            try self.reader.nextObjectEnd();
        }
        try self.reader.nextObjectEnd();
        try self.putShape(shape_hash, shape_type, try members.toOwnedSlice(self.allocator));
    }
}

fn parseMember(self: *Self, shape_id: []const u8, shape_members: *std.ArrayListUnmanaged(ShapeId)) !void {
        const member_id = try self.reader.nextString();
        const member_hash = ShapeId.compose(shape_id, member_id);
    try shape_members.append(self.allocator, member_hash);
        try self.reader.nextObjectBegin();
    while (try self.reader.peek() == .string) {
        try self.parseMemberProperty(member_hash);
    }
    try self.reader.nextObjectEnd();
}

fn parseMemberProperty(self: *Self, member_hash: ShapeId) !void {
        const property = try self.reader.nextString();
        if (mem.eql(u8, "target", property)) {
            const target = ShapeId.full(try self.reader.nextString());
        try self.putShape(member_hash, target, null);
        } else if (mem.eql(u8, "traits", property)) {
            try self.reader.nextObjectBegin();
            try self.reader.skipCurrentScope();
        } else {
        std.log.warn("Unknown member property: {s}.", .{property});
        try self.reader.skipValueOrScope();
    }
}

fn putShape(self: *Self, id: ShapeId, typ: ShapeId, members: ?[]const ShapeId) !void {
    const is_member = members == null;
    try self.shapes.put(self.allocator, id, switch (typ) {
        // zig fmt: off
        inline .blob, .boolean, .string, .byte, .short, .integer, .long,
        .float, .double, .big_integer, .big_decimal, .timestamp, .document,
            => |t| std.enums.nameCast(SmithyType, t),
        // zig fmt: on
        .unit => if (is_member) SmithyType.unit else return error.InvalidShapeTarget,
        .@"enum" => .{
            .@"enum" = members orelse return error.InvalidMemberTarget,
        },
        .int_enum => .{
            .int_enum = members orelse return error.InvalidMemberTarget,
        },
        .list => .{
            .list = (members orelse return error.InvalidMemberTarget)[0],
        },
        .map => .{
            .map = (members orelse return error.InvalidMemberTarget)[0..2].*,
        },
        .structure => .{
            .structure = members orelse return error.InvalidMemberTarget,
        },
        .@"union" => .{
            .@"union" = members orelse return error.InvalidMemberTarget,
        },
        _ => if (is_member) .{ .shape = typ } else return error.UnknownType,
    });
}

test "parseJsonModel" {
    var input_arena = std.heap.ArenaAllocator.init(test_alloc);
    var output_arena = std.heap.ArenaAllocator.init(test_alloc);
    defer {
        input_arena.deinit();
        output_arena.deinit();
    }

    const src: []const u8 = @embedFile("test.shapes.json");
    var stream = std.io.fixedBufferStream(src);
    const model = try parseJsonModel(
        input_arena.allocator(),
        output_arena.allocator(),
        stream.reader().any(),
    );

    try testing.expectEqual(.blob, model.getShape(ShapeId.full("test.simple#Blob")));
    try testing.expectEqual(.boolean, model.getShape(ShapeId.full("test.simple#Boolean")));
    try testing.expectEqual(.document, model.getShape(ShapeId.full("test.simple#Document")));
    try testing.expectEqual(.string, model.getShape(ShapeId.full("test.simple#String")));
    try testing.expectEqual(.byte, model.getShape(ShapeId.full("test.simple#Byte")));
    try testing.expectEqual(.short, model.getShape(ShapeId.full("test.simple#Short")));
    try testing.expectEqual(.integer, model.getShape(ShapeId.full("test.simple#Integer")));
    try testing.expectEqual(.long, model.getShape(ShapeId.full("test.simple#Long")));
    try testing.expectEqual(.float, model.getShape(ShapeId.full("test.simple#Float")));
    try testing.expectEqual(.double, model.getShape(ShapeId.full("test.simple#Double")));
    try testing.expectEqual(.big_integer, model.getShape(ShapeId.full("test.simple#BigInteger")));
    try testing.expectEqual(.big_decimal, model.getShape(ShapeId.full("test.simple#BigDecimal")));
    try testing.expectEqual(.timestamp, model.getShape(ShapeId.full("test.simple#Timestamp")));

    try testing.expectEqualDeep(
        SmithyType{ .@"enum" = &.{ShapeId.full("test.simple#Enum$FOO")} },
        model.getShape(ShapeId.full("test.simple#Enum")),
    );
    try testing.expectEqual(.unit, model.getShape(ShapeId.full("test.simple#Enum$FOO")));

    try testing.expectEqualDeep(
        SmithyType{ .int_enum = &.{ShapeId.full("test.simple#IntEnum$FOO")} },
        model.getShape(ShapeId.full("test.simple#IntEnum")),
    );
    try testing.expectEqual(.unit, model.getShape(ShapeId.full("test.simple#IntEnum$FOO")));

    try testing.expectEqualDeep(
        SmithyType{ .list = ShapeId.full("test.aggregate#List$member") },
        model.getShape(ShapeId.full("test.aggregate#List")),
    );
    try testing.expectEqual(.string, model.getShape(ShapeId.full("test.aggregate#List$member")));

    try testing.expectEqualDeep(
        SmithyType{ .map = .{ ShapeId.full("test.aggregate#Map$key"), ShapeId.full("test.aggregate#Map$value") } },
        model.getShape(ShapeId.full("test.aggregate#Map")),
    );
    try testing.expectEqual(.string, model.getShape(ShapeId.full("test.aggregate#Map$key")));
    try testing.expectEqual(.integer, model.getShape(ShapeId.full("test.aggregate#Map$value")));

    try testing.expectEqualDeep(
        SmithyType{ .structure = &.{
            ShapeId.full("test.aggregate#Structure$stringMember"),
            ShapeId.full("test.aggregate#Structure$numberMember"),
        } },
        model.getShape(ShapeId.full("test.aggregate#Structure")),
    );
    try testing.expectEqual(.string, model.getShape(ShapeId.full("test.aggregate#Structure$stringMember")));
    try testing.expectEqual(.integer, model.getShape(ShapeId.full("test.aggregate#Structure$numberMember")));

    try testing.expectEqualDeep(
        SmithyType{ .@"union" = &.{
            ShapeId.full("test.aggregate#Union$a"),
            ShapeId.full("test.aggregate#Union$b"),
        } },
        model.getShape(ShapeId.full("test.aggregate#Union")),
    );
    try testing.expectEqual(.string, model.getShape(ShapeId.full("test.aggregate#Union$a")));
    try testing.expectEqual(.integer, model.getShape(ShapeId.full("test.aggregate#Union$b")));
}

const Reader = struct {
    arena: Allocator,
    source: json.Reader(json.default_buffer_size, std.io.AnyReader),

    pub fn init(arena: Allocator, source: std.io.AnyReader) Reader {
        return .{
            .arena = arena,
            .source = std.json.reader(arena, source),
        };
    }

    /// Get the next token’s type without consuming it.
    pub fn peek(self: *Reader) !json.TokenType {
        return try self.source.peekNextTokenType();
    }

    /// Consume the following token.
    pub fn next(self: *Reader) !json.Token {
        return try self.source.nextAlloc(self.arena, .alloc_if_needed);
    }

    /// Get the next token, assuming it is an object.
    pub fn nextObjectBegin(self: *Reader) !void {
        const token = try self.next();
        assert(.object_begin == token);
    }

    /// Get the next token, assuming it is the end of an object.
    pub fn nextObjectEnd(self: *Reader) !void {
        const token = try self.next();
        assert(.object_end == token);
    }

    /// Get the next token, assuming it is an array.
    pub fn nextArrayBegin(self: *Reader) !void {
        const token = try self.next();
        assert(.array_begin == token);
    }

    /// Get the next token, assuming it is the end of an array.
    pub fn nextArrayEnd(self: *Reader) !void {
        const token = try self.next();
        assert(.array_end == token);
    }

    /// Get the next token, assuming it is the end of the document.
    pub fn nextDocumentEnd(self: *Reader) !void {
        const token = try self.next();
        assert(.end_of_document == token);
    }

    /// Get the next token, assuming it is a null value.
    pub fn nextNull(self: *Reader) !void {
        const token = try self.next();
        assert(.null == token);
    }

    /// Get the next token, assuming it is a boolean value.
    pub fn nextBool(self: *Reader) !bool {
        const token = try self.next();
        return switch (token) {
            .true => true,
            .false => false,
            else => unreachable,
        };
    }

    /// Get the next token, assuming it is an integer value.
    pub fn nextNumber(self: *Reader) !i64 {
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

    /// Get the next token, assuming it is a float value.
    pub fn nextFloat(self: *Reader) !f64 {
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

    /// Get the next token, assuming it is a string value.
    pub fn nextString(self: *Reader) ![]const u8 {
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
    pub fn nextStringEql(self: *Reader, expectd: []const u8) !void {
        const actual = try self.nextString();
        assert(mem.eql(u8, expectd, actual));
    }

    /// Assumes we already consumed the initial `*_begin`.
    pub fn skipCurrentScope(self: *Reader) !void {
        const current = self.source.stackHeight();
        assert(current > 0);
        try self.source.skipUntilStackHeight(current - 1);
    }

    /// Skips the following value, array, or object.
    pub fn skipValueOrScope(self: *Reader) !void {
        switch (try self.next()) {
            .object_begin, .array_begin => {
                const target = self.source.stackHeight() - 1;
                try self.source.skipUntilStackHeight(target);
            },
            else => {},
        }
    }
};

test "Reader" {
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

    var arena = std.heap.ArenaAllocator.init(test_alloc);
    defer arena.deinit();

    var stream = std.io.fixedBufferStream(input);
    var reader = Reader.init(arena.allocator(), stream.reader().any());

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
