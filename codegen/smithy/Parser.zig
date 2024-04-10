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
const SmithyMeta = identity.SmithyMeta;

const Self = @This();

const Context = struct {
    id: ?[]const u8 = null,
    hash: SmithyId = SmithyId.NULL,
    target: Target = .none,

    pub const Target = union(enum) {
        none,
        service: *Symbols.Service,
        resource: *Symbols.Resource,
        operation: *Symbols.Operation,
        id_list: *std.ArrayListUnmanaged(SmithyId),
        ref_map: *std.ArrayListUnmanaged(Symbols.RefMapValue),
        meta,
        meta_list: *std.ArrayListUnmanaged(SmithyMeta),
        meta_map: *std.ArrayListUnmanaged(SmithyMeta.Pair),
    };
};

arena: Allocator,
reader: *JsonReader,
manager: smntc.TraitManager,
service: SmithyId = SmithyId.NULL,
meta: std.AutoHashMapUnmanaged(SmithyId, SmithyMeta) = .{},
shapes: std.AutoHashMapUnmanaged(SmithyId, SmithyType) = .{},
traits: std.AutoHashMapUnmanaged(SmithyId, []const Symbols.TraitValue) = .{},
mixins: std.AutoHashMapUnmanaged(SmithyId, []const SmithyId) = .{},

/// Parse raw JSON into collection of Smithy symbols.
///
/// `arena` is used to store the parsed symbols and must be retained as long as
/// they are needed.
/// `json_reader` may be disposed immediately after calling this.
pub fn parseJson(arena: Allocator, json_reader: *JsonReader, traits: smntc.TraitManager) !Symbols {
    var parser = Self{
        .arena = arena,
        .reader = json_reader,
        .manager = traits,
    };
    errdefer {
        parser.meta.deinit(arena);
        parser.shapes.deinit(arena);
        parser.traits.deinit(arena);
        parser.mixins.deinit(arena);
    }

    try parser.parseScope(.object, parseProp, .{});
    try parser.reader.nextDocumentEnd();

    return .{
        .service = parser.service,
        .meta = parser.meta.move(),
        .shapes = parser.shapes.move(),
        .traits = parser.traits.move(),
        .mixins = parser.mixins.move(),
    };
}

fn parseScope(
    self: *Self,
    comptime scope: JsonReader.Scope,
    comptime parseFn: JsonReader.NextScopeFn(*Self, scope, Context),
    ctx: Context,
) !void {
    try self.reader.nextScope(*Self, scope, Context, parseFn, self, ctx);
}

fn parseProp(self: *Self, prop_id: []const u8, ctx: Context) !void {
    switch (identity.SmithyProperty.of(prop_id)) {
        .smithy => try self.validateSmithyVersion(),
        .mixins => try self.parseMixins(ctx.hash),
        .traits => try self.parseTraits(ctx.hash),
        .member, .key, .value => try self.parseMember(prop_id, ctx),
        .members => try self.parseScope(.object, parseMember, ctx),
        .shapes => try self.parseScope(.object, parseShape, .{}),
        .target => try self.putShape(ctx.hash, SmithyId.of(try self.reader.nextString()), .none),
        .metadata => try self.parseScope(.object, parseMetaMap, .{ .target = .meta }),
        .version => switch (ctx.target) {
            .service => |t| t.version = try self.arena.dupe(u8, try self.reader.nextString()),
            else => return error.InvalidShapeProperty,
        },
        inline .input, .output => |prop| switch (ctx.target) {
            .operation => |t| try self.parseShapeRefField(t, @tagName(prop)),
            else => return error.InvalidShapeProperty,
        },
        inline .create, .put, .read, .update, .delete, .list => |prop| switch (ctx.target) {
            .resource => |t| try self.parseShapeRefField(t, @tagName(prop)),
            else => return error.InvalidShapeProperty,
        },
        inline .operations, .resources => |prop| switch (ctx.target) {
            inline .service, .resource => |t| {
                try self.parseShapeRefList(t, @tagName(prop), false, parseShapeRefItem);
            },
            else => return error.InvalidShapeProperty,
        },
        inline .identifiers, .properties => |prop| switch (ctx.target) {
            .resource => |t| {
                try self.parseShapeRefList(t, @tagName(prop), true, parseShapeRefMapFrom);
            },
            else => return error.InvalidShapeProperty,
        },
        .errors => switch (ctx.target) {
            inline .service, .operation => |t| {
                try self.parseShapeRefList(t, "errors", false, parseShapeRefItem);
            },
            else => return error.InvalidShapeProperty,
        },
        .collection_ops => switch (ctx.target) {
            .resource => |t| {
                try self.parseShapeRefList(t, "collection_ops", false, parseShapeRefItem);
            },
            else => return error.InvalidShapeProperty,
        },
        .rename => switch (ctx.target) {
            .service => |t| {
                try self.parseShapeRefList(t, "rename", true, parseShapeRefMapTo);
            },
            else => return error.InvalidShapeProperty,
        },
        else => {
            if (ctx.id) |parent|
                std.log.warn("Unexpected property: `{s}${s}`.", .{ parent, prop_id })
            else
                std.log.warn("Unexpected property: `{s}`.", .{prop_id});
            try self.reader.skipValueOrScope();
        },
    }
}

fn parseMember(self: *Self, prop_id: []const u8, ctx: Context) !void {
    const member_hash = SmithyId.compose(ctx.id.?, prop_id);
    try ctx.target.id_list.append(self.arena, member_hash);
    const scp = Context{ .id = ctx.id, .hash = member_hash };
    try self.parseScope(.object, parseProp, scp);
}

fn parseShapeRefList(
    self: *Self,
    target: anytype,
    comptime field: []const u8,
    comptime map: bool,
    parsFn: JsonReader.NextScopeFn(*Self, if (map) .object else .array, Context),
) !void {
    var list = std.ArrayListUnmanaged(if (map) Symbols.RefMapValue else SmithyId){};
    errdefer list.deinit(self.arena);
    if (map)
        try self.parseScope(.object, parsFn, .{ .target = .{ .ref_map = &list } })
    else
        try self.parseScope(.array, parsFn, .{ .target = .{ .id_list = &list } });
    @field(target, field) = try list.toOwnedSlice(self.arena);
}

fn parseShapeRefItem(self: *Self, ctx: Context) !void {
    try ctx.target.id_list.append(self.arena, try self.parseShapeRef());
}

/// `"forecastId": { "target": "smithy.api#String" }`
fn parseShapeRefMapFrom(self: *Self, prop: []const u8, ctx: Context) !void {
    const shape = try self.parseShapeRef();
    const name = try self.arena.dupe(u8, prop);
    try ctx.target.ref_map.append(self.arena, .{ .name = name, .shape = shape });
}

/// `"foo.example#Widget": "FooWidget"`
fn parseShapeRefMapTo(self: *Self, prop: []const u8, ctx: Context) !void {
    const shape = SmithyId.of(prop);
    const name = try self.arena.dupe(u8, try self.reader.nextString());
    try ctx.target.ref_map.append(self.arena, .{ .name = name, .shape = shape });
}

fn parseShapeRefField(self: *Self, target: anytype, comptime field: []const u8) !void {
    @field(target, field) = try self.parseShapeRef();
}

/// An AST shape reference is an object with only a `target` property that maps
/// to an absolute shape ID.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/json-ast.html#ast-shape-reference)
fn parseShapeRef(self: *Self) !SmithyId {
    try self.reader.nextObjectBegin();
    try self.reader.nextStringEql("target");
    const shape_ref = SmithyId.of(try self.reader.nextString());
    try self.reader.nextObjectEnd();
    return shape_ref;
}

fn parseMixins(self: *Self, parent_hash: SmithyId) !void {
    var mixins = std.ArrayListUnmanaged(SmithyId){};
    errdefer mixins.deinit(self.arena);
    try self.parseScope(.array, parseShapeRefItem, .{
        .target = .{ .id_list = &mixins },
    });
    const slice = try mixins.toOwnedSlice(self.arena);
    try self.mixins.put(self.arena, parent_hash, slice);
}

fn parseTraits(self: *Self, parent_hash: SmithyId) !void {
    var traits: std.ArrayListUnmanaged(Symbols.TraitValue) = .{};
    errdefer traits.deinit(self.arena);
    try self.reader.nextObjectBegin();
    while (try self.reader.peek() == .string) {
        const trait_id = try self.reader.nextString();
        const trait_hash = SmithyId.of(trait_id);
        if (self.manager.parse(trait_hash, self.arena, self.reader)) |value| {
            try traits.append(
                self.arena,
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

    // ‘Apply’ types add external traits, in this case we merge the lists.
    if (self.traits.getPtr(parent_hash)) |items| {
        try traits.appendSlice(self.arena, items.*);
        self.arena.free(items.*);
    }

    const slice = try traits.toOwnedSlice(self.arena);
    try self.traits.put(self.arena, parent_hash, slice);
}

fn parseShape(self: *Self, shape_id: []const u8, _: Context) !void {
    const shape_hash = SmithyId.of(shape_id);
    try self.reader.nextObjectBegin();
    try self.reader.nextStringEql("type");
    const typ = SmithyId.of(try self.reader.nextString());
    const target: Context.Target = switch (typ) {
        .apply => {
            try self.parseScope(.current, parseProp, Context{
                .id = shape_id,
                .hash = shape_hash,
            });
            // Not a standalone shape, skip the creation/override of a shape symbol.
            try self.reader.nextObjectEnd();
            return;
        },
        .service => .{ .service = blk: {
            const ptr = try self.arena.create(Symbols.Service);
            ptr.* = std.mem.zeroInit(Symbols.Service, .{});
            break :blk ptr;
        } },
        .resource => .{ .resource = blk: {
            const ptr = try self.arena.create(Symbols.Resource);
            ptr.* = std.mem.zeroInit(Symbols.Resource, .{});
            break :blk ptr;
        } },
        .operation => .{ .operation = blk: {
            const ptr = try self.arena.create(Symbols.Operation);
            ptr.* = std.mem.zeroInit(Symbols.Operation, .{});
            break :blk ptr;
        } },
        else => blk: {
            var members: std.ArrayListUnmanaged(SmithyId) = .{};
            break :blk .{ .id_list = &members };
        },
    };
    errdefer switch (target) {
        inline .service, .resource, .operation => |p| self.arena.destroy(p),
        .id_list => |p| p.deinit(self.arena),
        else => {},
    };
    try self.parseScope(.current, parseProp, Context{
        .id = shape_id,
        .hash = shape_hash,
        .target = target,
    });
    try self.putShape(shape_hash, typ, target);
    try self.reader.nextObjectEnd();
}

fn putShape(self: *Self, id: SmithyId, typ: SmithyId, target: Context.Target) !void {
    try self.shapes.put(self.arena, id, switch (typ) {
        .unit => switch (target) {
            .none => SmithyType.unit,
            else => return error.InvalidShapeTarget,
        },
        // zig fmt: off
        inline .blob, .boolean, .string, .byte, .short, .integer, .long,
        .float, .double, .big_integer, .big_decimal, .timestamp, .document,
            => |t| std.enums.nameCast(SmithyType, t),
        // zig fmt: on
        inline .@"enum", .int_enum, .structure, .@"union" => |t| switch (target) {
            .id_list => |l| @unionInit(
                SmithyType,
                @tagName(t),
                try l.toOwnedSlice(self.arena),
            ),
            else => return error.InvalidMemberTarget,
        },
        .list => switch (target) {
            .id_list => |l| .{ .list = l.items[0] },
            else => return error.InvalidMemberTarget,
        },
        .map => switch (target) {
            .id_list => |l| .{ .map = l.items[0..2].* },
            else => return error.InvalidMemberTarget,
        },
        .operation => switch (target) {
            .operation => |val| .{ .operation = val },
            else => return error.InvalidMemberTarget,
        },
        .resource => switch (target) {
            .resource => |val| .{ .resource = val },
            else => return error.InvalidMemberTarget,
        },
        .service => switch (target) {
            .service => |val| blk: {
                self.service = id;
                break :blk .{ .service = val };
            },
            else => return error.InvalidMemberTarget,
        },
        .apply => unreachable,
        _ => switch (target) {
            .none => .{ .target = typ },
            else => return error.UnknownType,
        },
    });
}

fn parseMetaList(self: *Self, ctx: Context) !void {
    try ctx.target.meta_list.append(self.arena, try self.parseMetaValue());
}

fn parseMetaMap(self: *Self, meta_id: []const u8, ctx: Context) !void {
    const meta_hash = SmithyId.of(meta_id);
    const value = try self.parseMetaValue();
    switch (ctx.target) {
        .meta => try self.meta.put(self.arena, meta_hash, value),
        .meta_map => |m| try m.append(self.arena, .{ .key = meta_hash, .value = value }),
        else => unreachable,
    }
}

fn parseMetaValue(self: *Self) !SmithyMeta {
    switch (try self.reader.peek()) {
        .null => {
            try self.reader.skipValueOrScope();
            return .null;
        },
        .number => return switch (try self.reader.nextNumber()) {
            .integer => |n| .{ .integer = n },
            .float => |n| .{ .float = n },
        },
        .true, .false => return .{ .boolean = try self.reader.nextBoolean() },
        .string => return .{
            .string = try self.arena.dupe(u8, try self.reader.nextString()),
        },
        .array_begin => {
            var items: std.ArrayListUnmanaged(SmithyMeta) = .{};
            errdefer items.deinit(self.arena);
            try self.parseScope(.array, parseMetaList, .{
                .target = .{ .meta_list = &items },
            });
            return .{ .list = try items.toOwnedSlice(self.arena) };
        },
        .object_begin => {
            var items: std.ArrayListUnmanaged(SmithyMeta.Pair) = .{};
            errdefer items.deinit(self.arena);
            try self.parseScope(.object, parseMetaMap, .{
                .target = .{ .meta_map = &items },
            });
            return .{ .map = try items.toOwnedSlice(self.arena) };
        },
        else => unreachable,
    }
}

fn validateSmithyVersion(self: *Self) !void {
    const version = try self.reader.nextString();
    const valid = std.mem.eql(u8, "2.0", version) or std.mem.eql(u8, "2", version);
    if (!valid) return error.InvalidVersion;
}

test "parseJson" {
    var manager = smntc.TraitManager{};
    defer manager.deinit(test_alloc);
    try manager.register(test_alloc, SmithyId.of("test.trait#Void"), TestTraits.traitVoid());
    try manager.register(test_alloc, SmithyId.of("test.trait#Int"), TestTraits.traitInt());
    try manager.register(test_alloc, SmithyId.of("smithy.api#enumValue"), TestTraits.traitEnum());

    var input_arena = std.heap.ArenaAllocator.init(test_alloc);
    errdefer input_arena.deinit();

    var reader = try JsonReader.initFixed(input_arena.allocator(), @embedFile("tests/shapes.json"));
    errdefer reader.deinit();

    var output_arena = std.heap.ArenaAllocator.init(test_alloc);
    defer output_arena.deinit();

    const symbols = try parseJson(output_arena.allocator(), &reader, manager);
    // We dispose the reader to make sure the required data is copied:
    reader.deinit();
    input_arena.deinit();

    //
    // Metadata
    //

    try testing.expectEqual(.null, symbols.getMeta(SmithyId.of("nul")));
    try testing.expectEqualDeep(SmithyMeta{ .boolean = true }, symbols.getMeta(SmithyId.of("bol")));
    try testing.expectEqualDeep(SmithyMeta{ .integer = 108 }, symbols.getMeta(SmithyId.of("int")));
    try testing.expectEqualDeep(SmithyMeta{ .float = 1.08 }, symbols.getMeta(SmithyId.of("flt")));
    try testing.expectEqualDeep(SmithyMeta{ .string = "foo" }, symbols.getMeta(SmithyId.of("str")));
    try testing.expectEqualDeep(SmithyMeta{
        .list = &.{ .{ .integer = 108 }, .{ .integer = 109 } },
    }, symbols.getMeta(SmithyId.of("lst")));
    try testing.expectEqualDeep(SmithyMeta{
        .map = &.{.{ .key = SmithyId.of("key"), .value = .{ .integer = 108 } }},
    }, symbols.getMeta(SmithyId.of("map")));

    //
    // Shapes
    //

    try testing.expectEqual(.blob, symbols.getShape(SmithyId.of("test.simple#Blob")));
    try testing.expect(symbols.hasTrait(
        SmithyId.of("test.simple#Blob"),
        SmithyId.of("test.trait#Void"),
    ));

    try testing.expectEqual(.boolean, symbols.getShape(SmithyId.of("test.simple#Boolean")));
    try testing.expectEqualDeep(
        &.{SmithyId.of("test.mixin#Mixin")},
        symbols.getMixins(SmithyId.of("test.simple#Boolean")),
    );

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
    try testing.expectEqual(.string, symbols.getShape(SmithyId.of("test.aggregate#Structure$stringMember")));
    try testing.expect(symbols.hasTrait(SmithyId.of("test.aggregate#Structure$stringMember"), SmithyId.of("test.trait#Void")));
    try testing.expectEqual(
        108,
        symbols.getTrait(SmithyId.of("test.aggregate#Structure$stringMember"), SmithyId.of("test.trait#Int"), i64),
    );

    try testing.expectEqual(.integer, symbols.getShape(SmithyId.of("test.aggregate#Structure$numberMember")));
    // The traits merged with external `apply` traits.
    try testing.expect(symbols.hasTrait(SmithyId.of("test.aggregate#Structure$numberMember"), SmithyId.of("test.trait#Void")));
    try testing.expectEqual(
        108,
        symbols.getTrait(SmithyId.of("test.aggregate#Structure$numberMember"), SmithyId.of("test.trait#Int"), i64),
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

    try testing.expectEqualDeep(SmithyType{
        .operation = &.{
            .input = SmithyId.of("test.operation#Input"),
            .output = SmithyId.of("test.operation#Output"),
            .errors = &.{
                SmithyId.of("test.error#BadRequestError"),
                SmithyId.of("test.error#NotFoundError"),
            },
        },
    }, symbols.getShape(SmithyId.of("test.serve#Operation")));

    try testing.expectEqualDeep(SmithyType{
        .resource = &.{
            .identifiers = &.{
                .{ .name = "forecastId", .shape = SmithyId.of("smithy.api#String") },
            },
            .create = SmithyId.of("test.resource#Create"),
            .read = SmithyId.of("test.resource#Get"),
            .update = SmithyId.of("test.resource#Update"),
            .delete = SmithyId.of("test.resource#Delete"),
            .list = SmithyId.of("test.resource#List"),
            .operations = &.{SmithyId.of("test.resource#InstanceOperation")},
            .collection_ops = &.{SmithyId.of("test.resource#CollectionOperation")},
            .resources = &.{SmithyId.of("test.resource#OtherResource")},
        },
    }, symbols.getShape(SmithyId.of("test.serve#Resource")));

    try testing.expectEqualDeep(SmithyType{
        .service = &.{
            .version = "2017-02-11",
            .operations = &.{SmithyId.of("test.serve#Operation")},
            .resources = &.{SmithyId.of("test.serve#Resource")},
            .errors = &.{SmithyId.of("test.serve#Error")},
            .rename = &.{
                .{ .name = "NewFoo", .shape = SmithyId.of("foo.example#Foo") },
                .{ .name = "NewBar", .shape = SmithyId.of("bar.example#Bar") },
            },
        },
    }, symbols.getShape(SmithyId.of("test.serve#Service")));
    try testing.expectEqual(
        108,
        symbols.getTrait(SmithyId.of("test.serve#Service"), SmithyId.of("test.trait#Int"), i64),
    );
    try testing.expectEqual(SmithyId.of("test.serve#Service"), symbols.service);
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
        const value = try reader.nextInteger();
        const ptr = try allocator.create(i64);
        ptr.* = value;
        return ptr;
    }

    pub const EnumValue = union(enum) { integer: i32, string: []const u8 };
    fn parseEnum(_: *const anyopaque, allocator: Allocator, reader: *JsonReader) !*const anyopaque {
        const value = try allocator.create(EnumValue);
        value.* = switch (try reader.peek()) {
            .number => .{ .integer = @intCast(try reader.nextInteger()) },
            .string => blk: {
                break :blk .{ .string = try allocator.dupe(u8, try reader.nextString()) };
            },
            else => unreachable,
        };
        return value;
    }
};
