//! Smithy parser for [JSON AST](https://smithy.io/2.0/spec/json-ast.html) representation.
const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const JsonReader = @import("utils/JsonReader.zig");
const smntc = @import("semantic/trait.zig");
const identity = @import("semantic/identity.zig");
const Symbols = identity.Symbols;
const SmithyId = identity.SmithyId;
const SmithyType = identity.SmithyType;

const Self = @This();
const ParseScope = struct {
    id: ?[]const u8 = null,
    hash: SmithyId = @enumFromInt(0),
    target: ?*anyopaque = null,
};

allocator: Allocator,
reader: *JsonReader,
manager: smntc.TraitManager,
shapes: std.AutoHashMapUnmanaged(SmithyId, SmithyType) = .{},
traits: std.AutoHashMapUnmanaged(SmithyId, []const Symbols.TraitValue) = .{},

/// Parse raw JSON into collection of Smithy symbols.
///
/// `allocactor` is used to store the parsed symbols and must be retained as long
/// as they are needed.
/// `json_reader` may be disposed immediately after calling this.
pub fn parseJson(allocator: Allocator, json_reader: *JsonReader, traits: smntc.TraitManager) !Symbols {
    var parser = Self{
        .allocator = allocator,
        .reader = json_reader,
        .manager = traits,
    };
    try parser.parseProps(true, parseProp, .{});
    try parser.reader.nextDocumentEnd();
    return .{
        .shapes = parser.shapes.move(),
        .traits = parser.traits.move(),
    };
}

const parsePropFn = fn (self: *Self, prop_id: []const u8, scope: ParseScope) anyerror!void;
fn parseProps(self: *Self, scope_in: bool, parseFn: parsePropFn, scope: ParseScope) !void {
    if (scope_in) try self.reader.nextObjectBegin();
    while (try self.reader.peek() == .string) {
        const prop_id = try self.reader.nextString();
        try parseFn(self, prop_id, scope);
    }
    if (scope_in) try self.reader.nextObjectEnd();
}

fn parseProp(self: *Self, prop_id: []const u8, scope: ParseScope) !void {
    switch (identity.SmithyProperty.of(prop_id)) {
        .smithy => try self.reader.nextStringEql("2.0"),
        .metadata => {
            std.log.warn("Parsing model’s metadata is not implemented.", .{});
            try self.reader.skipValueOrScope();
        },
        .target => try self.putShape(scope.hash, SmithyId.of(try self.reader.nextString()), null),
        .shapes => try self.parseProps(true, parseShape, .{}),
        .members => try self.parseProps(true, parseMember, scope),
        .member, .key, .value => try self.parseMember(prop_id, scope),
        .traits => try self.parseTraits(scope.hash),
        else => {
            if (scope.id) |parent|
                std.log.warn("Unexpected property: `{s}#{s}`.", .{ parent, prop_id })
            else
                std.log.warn("Unexpected property: `{s}`.", .{prop_id});
            try self.reader.skipValueOrScope();
        },
    }
}

fn parseMember(self: *Self, prop_id: []const u8, scope: ParseScope) !void {
    const members: *std.ArrayListUnmanaged(SmithyId) = @alignCast(@ptrCast(scope.target.?));
    const member_hash = SmithyId.compose(scope.id.?, prop_id);
    try members.append(self.allocator, member_hash);
    try self.parseProps(true, parseProp, .{ .id = prop_id, .hash = member_hash });
}

fn parseShape(self: *Self, shape_id: []const u8, _: ParseScope) !void {
    const shape_hash = SmithyId.of(shape_id);
    var members: std.ArrayListUnmanaged(SmithyId) = .{};
    try self.reader.nextObjectBegin();
    try self.reader.nextStringEql("type");
    const shape_type = SmithyId.of(try self.reader.nextString());
    try self.parseProps(false, parseProp, .{ .id = shape_id, .hash = shape_hash, .target = &members });
    try self.reader.nextObjectEnd();
    try self.putShape(shape_hash, shape_type, try members.toOwnedSlice(self.allocator));
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
        .@"enum" => .{ .@"enum" = members.? },
        .int_enum => .{ .int_enum = members.? },
        .list => .{ .list = members.?[0] },
        .map => .{ .map = members.?[0..2].* },
        .structure => .{ .structure = members.? },
        .@"union" => .{ .@"union" = members.? },
        _ => if (is_member) .{ .target = typ } else return error.UnknownType,
    });
}

fn parseTraits(self: *Self, parent_hash: SmithyId) !void {
    var traits: std.ArrayListUnmanaged(Symbols.TraitValue) = .{};
    try self.reader.nextObjectBegin();
    while (try self.reader.peek() == .string) {
        const trait_id = try self.reader.nextString();
        const trait_hash = SmithyId.of(trait_id);
        if (self.manager.parse(trait_hash, self.allocator, self.reader)) |value| {
            try traits.append(
                self.allocator,
                .{ .id = trait_hash, .value = value },
            );
        } else |e| switch (e) {
            error.UnknownTrait => {
                std.log.warn("Unknown trait: {s}.", .{trait_id});
                try self.reader.skipValueOrScope();
                continue;
            },
            else => return e,
        }
    }
    try self.reader.nextObjectEnd();
    if (traits.items.len == 0) return;
    const slice = try traits.toOwnedSlice(self.allocator);
    try self.traits.put(self.allocator, parent_hash, slice);
}

test "parseJson" {
    var manager = smntc.TraitManager{};
    defer manager.deinit(test_alloc);
    try manager.register(test_alloc, SmithyId.of("test.trait#Void"), TestTraits.traitVoid());
    try manager.register(test_alloc, SmithyId.of("test.trait#Int"), TestTraits.traitInt());
    try manager.register(test_alloc, SmithyId.of("smithy.api#enumValue"), TestTraits.traitEnum());

    const src: []const u8 = @embedFile("tests/shapes.json");
    var stream = std.io.fixedBufferStream(src);
    var reader = JsonReader.init(test_alloc, stream.reader().any());

    var output_arena = std.heap.ArenaAllocator.init(test_alloc);
    defer output_arena.deinit();

    const symbols = try parseJson(output_arena.allocator(), &reader, manager);
    reader.deinit(); // We despose the reader to make sure the required data is copied.

    try testing.expectEqual(.blob, symbols.getShape(SmithyId.of("test.simple#Blob")));
    try testing.expect(symbols.hasTrait(SmithyId.of("test.simple#Blob"), SmithyId.of("test.trait#Void")));

    try testing.expectEqual(.boolean, symbols.getShape(SmithyId.of("test.simple#Boolean")));
    try testing.expectEqual(.document, symbols.getShape(SmithyId.of("test.simple#Document")));
    try testing.expectEqual(.string, symbols.getShape(SmithyId.of("test.simple#String")));
    try testing.expectEqual(.byte, symbols.getShape(SmithyId.of("test.simple#Byte")));
    try testing.expectEqual(.short, symbols.getShape(SmithyId.of("test.simple#Short")));
    try testing.expectEqual(.integer, symbols.getShape(SmithyId.of("test.simple#Integer")));
    try testing.expectEqual(.long, symbols.getShape(SmithyId.of("test.simple#Long")));
    try testing.expectEqual(.float, symbols.getShape(SmithyId.of("test.simple#Float")));
    try testing.expectEqual(.double, symbols.getShape(SmithyId.of("test.simple#Double")));
    try testing.expectEqual(.big_integer, symbols.getShape(SmithyId.of("test.simple#BigInteger")));
    try testing.expectEqual(.big_decimal, symbols.getShape(SmithyId.of("test.simple#BigDecimal")));
    try testing.expectEqual(.timestamp, symbols.getShape(SmithyId.of("test.simple#Timestamp")));

    try testing.expectEqualDeep(
        SmithyType{ .@"enum" = &.{SmithyId.of("test.simple#Enum$FOO")} },
        symbols.getShape(SmithyId.of("test.simple#Enum")),
    );
    try testing.expectEqual(.unit, symbols.getShape(SmithyId.of("test.simple#Enum$FOO")));
    try testing.expectEqualDeep(TestTraits.EnumValue{ .string = "foo" }, symbols.getTrait(
        SmithyId.of("test.simple#Enum$FOO"),
        SmithyId.of("smithy.api#enumValue"),
        TestTraits.EnumValue,
    ));

    try testing.expectEqualDeep(
        SmithyType{ .int_enum = &.{SmithyId.of("test.simple#IntEnum$FOO")} },
        symbols.getShape(SmithyId.of("test.simple#IntEnum")),
    );
    try testing.expectEqual(.unit, symbols.getShape(SmithyId.of("test.simple#IntEnum$FOO")));
    try testing.expectEqual(TestTraits.EnumValue{ .integer = 1 }, symbols.getTrait(
        SmithyId.of("test.simple#IntEnum$FOO"),
        SmithyId.of("smithy.api#enumValue"),
        TestTraits.EnumValue,
    ));

    try testing.expectEqualDeep(
        SmithyType{ .list = SmithyId.of("test.aggregate#List$member") },
        symbols.getShape(SmithyId.of("test.aggregate#List")),
    );
    try testing.expectEqual(.string, symbols.getShape(SmithyId.of("test.aggregate#List$member")));
    try testing.expect(symbols.hasTrait(SmithyId.of("test.aggregate#List$member"), SmithyId.of("test.trait#Void")));

    try testing.expectEqualDeep(
        SmithyType{ .map = .{ SmithyId.of("test.aggregate#Map$key"), SmithyId.of("test.aggregate#Map$value") } },
        symbols.getShape(SmithyId.of("test.aggregate#Map")),
    );
    try testing.expectEqual(.string, symbols.getShape(SmithyId.of("test.aggregate#Map$key")));
    try testing.expectEqual(.integer, symbols.getShape(SmithyId.of("test.aggregate#Map$value")));

    try testing.expectEqualDeep(
        SmithyType{ .structure = &.{
            SmithyId.of("test.aggregate#Structure$stringMember"),
            SmithyId.of("test.aggregate#Structure$numberMember"),
        } },
        symbols.getShape(SmithyId.of("test.aggregate#Structure")),
    );
    try testing.expectEqual(.integer, symbols.getShape(SmithyId.of("test.aggregate#Structure$numberMember")));
    try testing.expectEqual(.string, symbols.getShape(SmithyId.of("test.aggregate#Structure$stringMember")));
    try testing.expect(symbols.hasTrait(SmithyId.of("test.aggregate#Structure$stringMember"), SmithyId.of("test.trait#Void")));
    try testing.expectEqual(
        108,
        symbols.getTrait(SmithyId.of("test.aggregate#Structure$stringMember"), SmithyId.of("test.trait#Int"), i64),
    );

    try testing.expectEqualDeep(
        SmithyType{ .@"union" = &.{
            SmithyId.of("test.aggregate#Union$a"),
            SmithyId.of("test.aggregate#Union$b"),
        } },
        symbols.getShape(SmithyId.of("test.aggregate#Union")),
    );
    try testing.expectEqual(.string, symbols.getShape(SmithyId.of("test.aggregate#Union$a")));
    try testing.expectEqual(.integer, symbols.getShape(SmithyId.of("test.aggregate#Union$b")));
}

const TestTraits = struct {
    pub fn traitVoid() smntc.Trait {
        return .{ .ctx = undefined, .vtable = &.{ .parse = null } };
    }

    pub fn traitInt() smntc.Trait {
        return .{ .ctx = undefined, .vtable = &.{ .parse = parseInt } };
    }

    pub fn traitEnum() smntc.Trait {
        return .{ .ctx = undefined, .vtable = &.{ .parse = parseEnum } };
    }

    fn parseInt(_: *const anyopaque, allocator: Allocator, reader: *JsonReader) !*const anyopaque {
        const value = try reader.nextNumber();
        const ptr = try allocator.create(i64);
        ptr.* = value;
        return ptr;
    }

    pub const EnumValue = union(enum) { integer: i32, string: []const u8 };
    fn parseEnum(_: *const anyopaque, allocator: Allocator, reader: *JsonReader) !*const anyopaque {
        const value = try allocator.create(EnumValue);
        value.* = switch (try reader.peek()) {
            .number => .{ .integer = @intCast(try reader.nextNumber()) },
            .string => blk: {
                break :blk .{ .string = try allocator.dupe(u8, try reader.nextString()) };
            },
            else => unreachable,
        };
        return value;
    }
};
