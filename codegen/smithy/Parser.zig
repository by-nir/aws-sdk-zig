//! Smithy parser for [JSON AST](https://smithy.io/2.0/spec/json-ast.html) representation.
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const identity = @import("identity.zig");
const SmithyId = identity.SmithyId;
const SmithyType = identity.SmithyType;
const JsonReader = @import("JsonReader.zig");

const Self = @This();

allocator: Allocator,
reader: *JsonReader,
shapes: std.AutoHashMapUnmanaged(SmithyId, SmithyType) = .{},

/// Parse raw JSON into collection of Smithy symbols.
///
/// `allocactor` is used to store the parsed symbols and must be retained as long
/// as they are needed.
/// `json_reader` may be disposed immediately after calling this.
pub fn parseJson(allocator: Allocator, json_reader: *JsonReader) !Symbols {
    var parser = Self{
        .allocator = allocator,
        .reader = json_reader,
    };

    try parser.reader.nextObjectBegin();
    try parser.validateSmithy();
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

    return .{
        .shapes = parser.shapes.move(),
    };
}

fn validateSmithy(self: *Self) !void {
    try self.reader.nextStringEql("smithy");
    try self.reader.nextStringEql("2.0");
}

fn parseShapes(self: *Self) !void {
    while (try self.reader.peek() == .string) {
        const shape_id = try self.reader.nextString();
        const shape_hash = SmithyId.full(shape_id);
        try self.reader.nextObjectBegin();
        try self.reader.nextStringEql("type");
        const shape_type = SmithyId.full(try self.reader.nextString());

        var members: std.ArrayListUnmanaged(SmithyId) = .{};
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
                const member_type = SmithyId.full(try self.reader.nextString());
                const member_id = SmithyId.compose(shape_id, section);
                try members.append(self.allocator, member_id);
                try self.putShape(member_id, member_type, null);
            }
            try self.reader.nextObjectEnd();
        }
        try self.reader.nextObjectEnd();
        try self.putShape(shape_hash, shape_type, try members.toOwnedSlice(self.allocator));
    }
}

fn parseMember(self: *Self, shape_id: []const u8, shape_members: *std.ArrayListUnmanaged(SmithyId)) !void {
    const member_id = try self.reader.nextString();
    const member_hash = SmithyId.compose(shape_id, member_id);
    try shape_members.append(self.allocator, member_hash);
    try self.reader.nextObjectBegin();
    while (try self.reader.peek() == .string) {
        try self.parseMemberProperty(member_hash);
    }
    try self.reader.nextObjectEnd();
}

fn parseMemberProperty(self: *Self, member_hash: SmithyId) !void {
    const property = try self.reader.nextString();
    if (mem.eql(u8, "target", property)) {
        const target = SmithyId.full(try self.reader.nextString());
        try self.putShape(member_hash, target, null);
    } else if (mem.eql(u8, "traits", property)) {
        try self.reader.nextObjectBegin();
        try self.reader.skipCurrentScope();
    } else {
        std.log.warn("Unknown member property: {s}.", .{property});
        try self.reader.skipValueOrScope();
    }
}

fn putShape(self: *Self, id: SmithyId, typ: SmithyId, members: ?[]const SmithyId) !void {
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


test "parseJson" {
    const src: []const u8 = @embedFile("test.shapes.json");
    var stream = std.io.fixedBufferStream(src);
    var reader = JsonReader.init(test_alloc, stream.reader().any());

    var output_arena = std.heap.ArenaAllocator.init(test_alloc);
    defer output_arena.deinit();

    const symbols = try parseJson(output_arena.allocator(), &reader);
    reader.deinit(); // By desposing the reader we make sure the required data is copied.

    try testing.expectEqual(.blob, symbols.getShape(SmithyId.full("test.simple#Blob")));
    try testing.expectEqual(.boolean, symbols.getShape(SmithyId.full("test.simple#Boolean")));
    try testing.expectEqual(.document, symbols.getShape(SmithyId.full("test.simple#Document")));
    try testing.expectEqual(.string, symbols.getShape(SmithyId.full("test.simple#String")));
    try testing.expectEqual(.byte, symbols.getShape(SmithyId.full("test.simple#Byte")));
    try testing.expectEqual(.short, symbols.getShape(SmithyId.full("test.simple#Short")));
    try testing.expectEqual(.integer, symbols.getShape(SmithyId.full("test.simple#Integer")));
    try testing.expectEqual(.long, symbols.getShape(SmithyId.full("test.simple#Long")));
    try testing.expectEqual(.float, symbols.getShape(SmithyId.full("test.simple#Float")));
    try testing.expectEqual(.double, symbols.getShape(SmithyId.full("test.simple#Double")));
    try testing.expectEqual(.big_integer, symbols.getShape(SmithyId.full("test.simple#BigInteger")));
    try testing.expectEqual(.big_decimal, symbols.getShape(SmithyId.full("test.simple#BigDecimal")));
    try testing.expectEqual(.timestamp, symbols.getShape(SmithyId.full("test.simple#Timestamp")));

    try testing.expectEqualDeep(
        SmithyType{ .@"enum" = &.{SmithyId.full("test.simple#Enum$FOO")} },
        symbols.getShape(SmithyId.full("test.simple#Enum")),
    );
    try testing.expectEqual(.unit, symbols.getShape(SmithyId.full("test.simple#Enum$FOO")));

    try testing.expectEqualDeep(
        SmithyType{ .int_enum = &.{SmithyId.full("test.simple#IntEnum$FOO")} },
        symbols.getShape(SmithyId.full("test.simple#IntEnum")),
    );
    try testing.expectEqual(.unit, symbols.getShape(SmithyId.full("test.simple#IntEnum$FOO")));

    try testing.expectEqualDeep(
        SmithyType{ .list = SmithyId.full("test.aggregate#List$member") },
        symbols.getShape(SmithyId.full("test.aggregate#List")),
    );
    try testing.expectEqual(.string, symbols.getShape(SmithyId.full("test.aggregate#List$member")));

    try testing.expectEqualDeep(
        SmithyType{ .map = .{ SmithyId.full("test.aggregate#Map$key"), SmithyId.full("test.aggregate#Map$value") } },
        symbols.getShape(SmithyId.full("test.aggregate#Map")),
    );
    try testing.expectEqual(.string, symbols.getShape(SmithyId.full("test.aggregate#Map$key")));
    try testing.expectEqual(.integer, symbols.getShape(SmithyId.full("test.aggregate#Map$value")));

    try testing.expectEqualDeep(
        SmithyType{ .structure = &.{
            SmithyId.full("test.aggregate#Structure$stringMember"),
            SmithyId.full("test.aggregate#Structure$numberMember"),
        } },
        symbols.getShape(SmithyId.full("test.aggregate#Structure")),
    );
    try testing.expectEqual(.string, symbols.getShape(SmithyId.full("test.aggregate#Structure$stringMember")));
    try testing.expectEqual(.integer, symbols.getShape(SmithyId.full("test.aggregate#Structure$numberMember")));

    try testing.expectEqualDeep(
        SmithyType{ .@"union" = &.{
            SmithyId.full("test.aggregate#Union$a"),
            SmithyId.full("test.aggregate#Union$b"),
        } },
        symbols.getShape(SmithyId.full("test.aggregate#Union")),
    );
    try testing.expectEqual(.string, symbols.getShape(SmithyId.full("test.aggregate#Union$a")));
    try testing.expectEqual(.integer, symbols.getShape(SmithyId.full("test.aggregate#Union$b")));
}

/// Parsed symbols (shapes and metadata) from a Smithy model.
pub const Symbols = struct {
    shapes: std.AutoHashMapUnmanaged(SmithyId, SmithyType),

    pub fn getShape(self: Symbols, id: SmithyId) ?SmithyType {
        return self.shapes.get(id);
    }
};

test "Symbols" {
    var shapes: std.AutoHashMapUnmanaged(SmithyId, SmithyType) = .{};
    defer shapes.deinit(test_alloc);

    try shapes.put(test_alloc, SmithyId.full("test.simple#Blob"), .blob);
    const symbols = Symbols{ .shapes = shapes };

    try testing.expectEqual(.blob, symbols.getShape(SmithyId.full("test.simple#Blob")));
}
