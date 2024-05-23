//! Smithy parser for [JSON AST](https://smithy.io/2.0/spec/json-ast.html) representation.
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const JsonReader = @import("utils/JsonReader.zig");
const IssuesBag = @import("utils/IssuesBag.zig");
const syb_id = @import("symbols/identity.zig");
const SmithyId = syb_id.SmithyId;
const SmithyType = syb_id.SmithyType;
const syb_shape = @import("symbols/shapes.zig");
const SmithyMeta = syb_shape.SmithyMeta;
const SmithyModel = syb_shape.SmithyModel;
const TraitsManager = @import("symbols/traits.zig").TraitsManager;
const trt_refine = @import("traits/refine.zig");

const Self = @This();

pub const Policy = struct {
    property: IssuesBag.PolicyResolution,
    trait: IssuesBag.PolicyResolution,
};

const Context = struct {
    name: ?[]const u8 = null,
    id: SmithyId = SmithyId.NULL,
    target: Target = .none,

    pub const Target = union(enum) {
        none,
        service: *syb_shape.SmithyService,
        resource: *syb_shape.SmithyResource,
        operation: *syb_shape.SmithyOperation,
        id_list: *std.ArrayListUnmanaged(SmithyId),
        ref_map: *std.ArrayListUnmanaged(syb_id.SmithyRefMapValue),
        meta,
        meta_list: *std.ArrayListUnmanaged(SmithyMeta),
        meta_map: *std.ArrayListUnmanaged(SmithyMeta.Pair),
    };
};

arena: Allocator,
manager: TraitsManager,
policy: Policy,
issues: *IssuesBag,
reader: *JsonReader,
model: SmithyModel = .{},

/// Parse raw JSON into collection of Smithy symbols.
///
/// `arena` is used to store the parsed symbols and must be retained as long as
/// they are needed.
/// `json_reader` may be disposed immediately after calling this.
pub fn parseJson(
    arena: Allocator,
    traits: TraitsManager,
    policy: Policy,
    issues: *IssuesBag,
    json: *JsonReader,
) !SmithyModel {
    var parser = Self{
        .arena = arena,
        .manager = traits,
        .policy = policy,
        .issues = issues,
        .reader = json,
    };
    errdefer parser.model.deinit(arena);

    try parser.parseScope(.object, parseProp, .{});
    try parser.reader.nextDocumentEnd();
    return parser.model;
}

fn parseScope(
    self: *Self,
    comptime scope: JsonReader.Scope,
    comptime parseFn: JsonReader.NextScopeFn(*Self, Context, scope),
    ctx: Context,
) !void {
    try self.reader.nextScope(*Self, Context, scope, parseFn, self, ctx);
}

fn parseProp(self: *Self, prop_name: []const u8, ctx: Context) !void {
    switch (syb_id.SmithyProperty.of(prop_name)) {
        .smithy => try self.validateSmithyVersion(),
        .mixins => try self.parseMixins(ctx.id),
        .traits => try self.parseTraits(ctx.name.?, ctx.id),
        .member, .key, .value => try self.parseMember(prop_name, ctx),
        .members => try self.parseScope(.object, parseMember, ctx),
        .shapes => try self.parseScope(.object, parseShape, .{}),
        .target => {
            const shape = try self.reader.nextString();
            _ = try self.putShape(ctx.id, SmithyId.of(shape), shape, .none);
        },
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
        else => switch (self.policy.property) {
            .skip => {
                try self.issues.add(.{ .parse_unexpected_prop = .{
                    .context = ctx.name.?,
                    .item = prop_name,
                } });
                try self.reader.skipValueOrScope();
            },
            .abort => {
                std.log.err("Unexpected property: `{s}${s}`.", .{ ctx.name.?, prop_name });
                return IssuesBag.PolicyAbortError;
            },
        },
    }
}

fn parseMember(self: *Self, prop_name: []const u8, ctx: Context) !void {
    const parent_name = ctx.name.?;
    const len = 1 + parent_name.len + prop_name.len;
    std.debug.assert(len <= 128);

    var member_name: [128]u8 = undefined;
    @memcpy(member_name[0..parent_name.len], parent_name);
    member_name[parent_name.len] = '$';
    @memcpy(member_name[parent_name.len + 1 ..][0..prop_name.len], prop_name);

    const member_id = SmithyId.compose(parent_name, prop_name);
    if (!isManagedMember(prop_name)) try self.putName(member_id, .{ .member = prop_name });

    try ctx.target.id_list.append(self.arena, member_id);
    const scp = Context{ .id = member_id, .name = member_name[0..len] };
    try self.parseScope(.object, parseProp, scp);
}

fn isManagedMember(prop_name: []const u8) bool {
    return mem.eql(u8, prop_name, "member") or
        mem.eql(u8, prop_name, "key") or
        mem.eql(u8, prop_name, "value");
}

fn parseShapeRefList(
    self: *Self,
    target: anytype,
    comptime field: []const u8,
    comptime map: bool,
    parsFn: JsonReader.NextScopeFn(*Self, Context, if (map) .object else .array),
) !void {
    var list = std.ArrayListUnmanaged(if (map) syb_id.SmithyRefMapValue else SmithyId){};
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

fn parseMixins(self: *Self, parent_id: SmithyId) !void {
    var mixins = std.ArrayListUnmanaged(SmithyId){};
    errdefer mixins.deinit(self.arena);
    try self.parseScope(.array, parseShapeRefItem, .{
        .target = .{ .id_list = &mixins },
    });
    const slice = try mixins.toOwnedSlice(self.arena);
    try self.model.mixins.put(self.arena, parent_id, slice);
}

fn parseTraits(self: *Self, parent_name: []const u8, parent_id: SmithyId) !void {
    var traits: std.ArrayListUnmanaged(syb_id.SmithyTaggedValue) = .{};
    errdefer traits.deinit(self.arena);
    try self.reader.nextObjectBegin();
    while (try self.reader.peek() == .string) {
        const trait_name = try self.reader.nextString();
        const trait_id = SmithyId.of(trait_name);
        if (self.manager.parse(trait_id, self.arena, self.reader)) |value| {
            try traits.append(
                self.arena,
                .{ .id = trait_id, .value = value },
            );
        } else |e| switch (e) {
            error.UnknownTrait => switch (self.policy.trait) {
                .skip => {
                    try self.issues.add(.{ .parse_unknown_trait = .{
                        .context = parent_name,
                        .item = trait_name,
                    } });
                    try self.reader.skipValueOrScope();
                },
                .abort => {
                    std.log.err("Unknown trait: {s} ({s}).", .{ trait_name, parent_name });
                    return IssuesBag.PolicyAbortError;
                },
            },
            else => return e,
        }
    }
    try self.reader.nextObjectEnd();
    if (traits.items.len == 0) return;

    // ‘Apply’ types add external traits, in this case we merge the lists.
    if (self.model.traits.getPtr(parent_id)) |items| {
        try traits.appendSlice(self.arena, items.*);
        self.arena.free(items.*);
    }

    const slice = try traits.toOwnedSlice(self.arena);
    if (try self.putTraits(parent_id, slice)) {
        self.arena.free(slice);
    }
}

/// Returns `true` if already had traits.
fn putTraits(self: *Self, id: SmithyId, traits: []const syb_id.SmithyTaggedValue) !bool {
    const result = try self.model.traits.getOrPut(self.arena, id);
    if (result.found_existing) {
        const current_len = result.value_ptr.*.len;
        const all = try self.arena.alloc(syb_id.SmithyTaggedValue, current_len + traits.len);
        @memcpy(all[0..current_len], result.value_ptr.*);
        @memcpy(all[current_len..][0..traits.len], traits);
        self.arena.free(result.value_ptr.*);
        result.value_ptr.* = all;
    } else {
        try self.model.traits.put(self.arena, id, traits);
    }
    return result.found_existing;
}

fn parseShape(self: *Self, shape_name: []const u8, _: Context) !void {
    try self.reader.nextObjectBegin();
    try self.reader.nextStringEql("type");
    const shape_id = SmithyId.of(shape_name);
    const typ = SmithyId.of(try self.reader.nextString());
    const target: Context.Target = switch (typ) {
        .apply => {
            try self.parseScope(.current, parseProp, Context{
                .id = shape_id,
                .name = shape_name,
            });
            // Not a standalone shape, skip the creation/override of a shape symbol.
            return;
        },
        .service => .{ .service = blk: {
            const ptr = try self.arena.create(syb_shape.SmithyService);
            ptr.* = mem.zeroInit(syb_shape.SmithyService, .{});
            break :blk ptr;
        } },
        .resource => .{ .resource = blk: {
            const ptr = try self.arena.create(syb_shape.SmithyResource);
            ptr.* = mem.zeroInit(syb_shape.SmithyResource, .{});
            break :blk ptr;
        } },
        .operation => .{ .operation = blk: {
            const ptr = try self.arena.create(syb_shape.SmithyOperation);
            ptr.* = mem.zeroInit(syb_shape.SmithyOperation, .{});
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
        .name = shape_name,
        .id = shape_id,
        .target = target,
    });
    try self.putShape(shape_id, typ, shape_name, target);
}

fn putShape(self: *Self, id: SmithyId, type_id: SmithyId, name: []const u8, target: Context.Target) !void {
    var is_named = false;
    const smithy_type: SmithyType = switch (type_id) {
        .unit => switch (target) {
            .none => SmithyType.unit,
            else => return error.InvalidShapeTarget,
        },
        inline .boolean, .byte, .short, .integer, .long, .float, .double => |t| blk: {
            const Primitive = struct {
                const int = JsonReader.Value{ .integer = 0 };
                const float = JsonReader.Value{ .float = 0.0 };
                const boolean = JsonReader.Value{ .boolean = false };
            };
            if (mem.startsWith(u8, name, "smithy.api#Primitive")) {
                const traits = try self.arena.alloc(syb_id.SmithyTaggedValue, 1);
                traits[0] = .{
                    .id = trt_refine.Default.id,
                    .value = switch (t) {
                        .boolean => &Primitive.boolean,
                        .byte, .short, .integer, .long => &Primitive.int,
                        .float, .double => &Primitive.float,
                        else => unreachable,
                    },
                };
                if (try self.putTraits(id, traits)) {
                    self.arena.free(traits);
                }
            }
            break :blk std.enums.nameCast(SmithyType, t);
        },
        inline .blob, .string, .big_integer, .big_decimal, .timestamp, .document => |t| blk: {
            break :blk std.enums.nameCast(SmithyType, t);
        },
        inline .str_enum, .int_enum, .tagged_uinon, .structure => |t| switch (target) {
            .id_list => |l| blk: {
                is_named = true;
                break :blk @unionInit(
                    SmithyType,
                    @tagName(t),
                    try l.toOwnedSlice(self.arena),
                );
            },
            else => return error.InvalidMemberTarget,
        },
        .list => switch (target) {
            .id_list => |l| blk: {
                is_named = true;
                break :blk .{ .list = l.items[0] };
            },
            else => return error.InvalidMemberTarget,
        },
        .map => switch (target) {
            .id_list => |l| blk: {
                is_named = true;
                break :blk .{ .map = l.items[0..2].* };
            },
            else => return error.InvalidMemberTarget,
        },
        .operation => switch (target) {
            .operation => |val| blk: {
                is_named = true;
                break :blk .{ .operation = val };
            },
            else => return error.InvalidMemberTarget,
        },
        .resource => switch (target) {
            .resource => |val| blk: {
                is_named = true;
                break :blk .{ .resource = val };
            },
            else => return error.InvalidMemberTarget,
        },
        .service => switch (target) {
            .service => |val| blk: {
                is_named = true;
                self.model.service = id;
                break :blk .{ .service = val };
            },
            else => return error.InvalidMemberTarget,
        },
        .apply => unreachable,
        _ => switch (target) {
            .none => .{ .target = type_id },
            else => return error.UnknownType,
        },
    };
    try self.model.shapes.put(self.arena, id, smithy_type);
    if (is_named) try self.putName(id, .{ .absolute = name });
}

const Name = union(enum) { member: []const u8, absolute: []const u8 };
fn putName(self: *Self, id: SmithyId, name: Name) !void {
    const part = switch (name) {
        .member => |s| s,
        .absolute => |s| blk: {
            const split = mem.indexOfScalar(u8, s, '#');
            break :blk if (split) |i| s[i + 1 .. s.len] else s;
        },
    };
    try self.model.names.put(self.arena, id, try self.arena.dupe(u8, part));
}

fn parseMetaList(self: *Self, ctx: Context) !void {
    try ctx.target.meta_list.append(self.arena, try self.parseMetaValue());
}

fn parseMetaMap(self: *Self, meta_name: []const u8, ctx: Context) !void {
    const meta_id = SmithyId.of(meta_name);
    const value = try self.parseMetaValue();
    switch (ctx.target) {
        .meta => try self.model.meta.put(self.arena, meta_id, value),
        .meta_map => |m| try m.append(self.arena, .{ .key = meta_id, .value = value }),
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
    const valid = mem.eql(u8, "2.0", version) or mem.eql(u8, "2", version);
    if (!valid) return error.InvalidVersion;
}

test "parseJson" {
    const Traits = struct {
        fn parseInt(allocator: Allocator, reader: *JsonReader) !*const anyopaque {
            const value = try reader.nextInteger();
            const ptr = try allocator.create(i64);
            ptr.* = value;
            return ptr;
        }
    };

    var traits = TraitsManager{};
    defer traits.deinit(test_alloc);
    try traits.registerAll(test_alloc, &.{
        .{ SmithyId.of("test.trait#Void"), null },
        .{ SmithyId.of("test.trait#Int"), Traits.parseInt },
        .{ trt_refine.EnumValue.id, trt_refine.EnumValue.parse },
    });

    var input_arena = std.heap.ArenaAllocator.init(test_alloc);
    errdefer input_arena.deinit();
    var reader = try JsonReader.initFixed(input_arena.allocator(), @embedFile("testing/shapes.json"));
    errdefer reader.deinit();

    var issues = IssuesBag.init(test_alloc);
    defer issues.deinit();

    var output_arena = std.heap.ArenaAllocator.init(test_alloc);
    defer output_arena.deinit();
    const model = try parseJson(output_arena.allocator(), traits, .{
        .property = .skip,
        .trait = .skip,
    }, &issues, &reader);

    // Dispose the reader to make sure the required data is copied.
    reader.deinit();
    input_arena.deinit();

    //
    // Issues
    //

    try testing.expectEqualDeep(&[_]IssuesBag.Issue{
        .{ .parse_unknown_trait = .{
            .context = "test.aggregate#Structure$numberMember",
            .item = "test.trait#Unknown",
        } },
        .{ .parse_unexpected_prop = .{
            .context = "test.aggregate#Structure",
            .item = "unexpected",
        } },
    }, issues.all());

    //
    // Metadata
    //

    try testing.expectEqual(.null, model.getMeta(SmithyId.of("nul")));
    try testing.expectEqualDeep(SmithyMeta{ .boolean = true }, model.getMeta(SmithyId.of("bol")));
    try testing.expectEqualDeep(SmithyMeta{ .integer = 108 }, model.getMeta(SmithyId.of("int")));
    try testing.expectEqualDeep(SmithyMeta{ .float = 1.08 }, model.getMeta(SmithyId.of("flt")));
    try testing.expectEqualDeep(SmithyMeta{ .string = "foo" }, model.getMeta(SmithyId.of("str")));
    try testing.expectEqualDeep(SmithyMeta{
        .list = &.{ .{ .integer = 108 }, .{ .integer = 109 } },
    }, model.getMeta(SmithyId.of("lst")));
    try testing.expectEqualDeep(SmithyMeta{
        .map = &.{.{ .key = SmithyId.of("key"), .value = .{ .integer = 108 } }},
    }, model.getMeta(SmithyId.of("map")));

    //
    // Shapes
    //

    try testing.expectEqual(.blob, model.getShape(SmithyId.of("test.simple#Blob")));
    try testing.expect(model.hasTrait(
        SmithyId.of("test.simple#Blob"),
        SmithyId.of("test.trait#Void"),
    ));

    try testing.expectEqual(.boolean, model.getShape(SmithyId.of("test.simple#Boolean")));
    try testing.expectEqualDeep(
        &.{SmithyId.of("test.mixin#Mixin")},
        model.getMixins(SmithyId.of("test.simple#Boolean")),
    );

    try testing.expectEqual(.document, model.getShape(SmithyId.of("test.simple#Document")));
    try testing.expectEqual(.string, model.getShape(SmithyId.of("test.simple#String")));
    try testing.expectEqual(.byte, model.getShape(SmithyId.of("test.simple#Byte")));
    try testing.expectEqual(.short, model.getShape(SmithyId.of("test.simple#Short")));
    try testing.expectEqual(.integer, model.getShape(SmithyId.of("test.simple#Integer")));
    try testing.expectEqual(.long, model.getShape(SmithyId.of("test.simple#Long")));
    try testing.expectEqual(.float, model.getShape(SmithyId.of("test.simple#Float")));
    try testing.expectEqual(.double, model.getShape(SmithyId.of("test.simple#Double")));
    try testing.expectEqual(.big_integer, model.getShape(SmithyId.of("test.simple#BigInteger")));
    try testing.expectEqual(.big_decimal, model.getShape(SmithyId.of("test.simple#BigDecimal")));
    try testing.expectEqual(.timestamp, model.getShape(SmithyId.of("test.simple#Timestamp")));

    try testing.expectEqualDeep(
        SmithyType{ .str_enum = &.{SmithyId.of("test.simple#Enum$FOO")} },
        model.getShape(SmithyId.of("test.simple#Enum")),
    );
    try testing.expectEqual(.unit, model.getShape(SmithyId.of("test.simple#Enum$FOO")));
    try testing.expectEqualDeep(
        trt_refine.EnumValue.Val{ .string = "foo" },
        trt_refine.EnumValue.get(&model, SmithyId.of("test.simple#Enum$FOO")),
    );
    try testing.expectEqualStrings("Enum", try model.tryGetName(SmithyId.of("test.simple#Enum")));
    try testing.expectEqualStrings("FOO", try model.tryGetName(SmithyId.of("test.simple#Enum$FOO")));

    try testing.expectEqualDeep(
        SmithyType{ .int_enum = &.{SmithyId.of("test.simple#IntEnum$FOO")} },
        model.getShape(SmithyId.of("test.simple#IntEnum")),
    );
    try testing.expectEqual(.unit, model.getShape(SmithyId.of("test.simple#IntEnum$FOO")));
    try testing.expectEqual(
        trt_refine.EnumValue.Val{ .integer = 1 },
        trt_refine.EnumValue.get(&model, SmithyId.of("test.simple#IntEnum$FOO")),
    );
    try testing.expectEqualStrings("IntEnum", try model.tryGetName(SmithyId.of("test.simple#IntEnum")));
    try testing.expectEqualStrings(
        "FOO",
        try model.tryGetName(SmithyId.of("test.simple#IntEnum$FOO")),
    );

    try testing.expectEqualDeep(
        SmithyType{ .list = SmithyId.of("test.aggregate#List$member") },
        model.getShape(SmithyId.of("test.aggregate#List")),
    );
    try testing.expectEqual(.string, model.getShape(SmithyId.of("test.aggregate#List$member")));
    try testing.expect(model.hasTrait(
        SmithyId.of("test.aggregate#List$member"),
        SmithyId.of("test.trait#Void"),
    ));

    try testing.expectEqualDeep(
        SmithyType{ .map = .{
            SmithyId.of("test.aggregate#Map$key"),
            SmithyId.of("test.aggregate#Map$value"),
        } },
        model.getShape(SmithyId.of("test.aggregate#Map")),
    );
    try testing.expectEqual(.string, model.getShape(SmithyId.of("test.aggregate#Map$key")));
    try testing.expectEqual(.integer, model.getShape(SmithyId.of("test.aggregate#Map$value")));

    try testing.expectEqualDeep(
        SmithyType{ .structure = &.{
            SmithyId.of("test.aggregate#Structure$stringMember"),
            SmithyId.of("test.aggregate#Structure$numberMember"),
            SmithyId.of("test.aggregate#Structure$primitiveBool"),
            SmithyId.of("test.aggregate#Structure$primitiveByte"),
            SmithyId.of("test.aggregate#Structure$primitiveShort"),
            SmithyId.of("test.aggregate#Structure$primitiveInt"),
            SmithyId.of("test.aggregate#Structure$primitiveLong"),
            SmithyId.of("test.aggregate#Structure$primitiveFloat"),
            SmithyId.of("test.aggregate#Structure$primitiveDouble"),
        } },
        model.getShape(SmithyId.of("test.aggregate#Structure")),
    );
    try testing.expectEqualStrings("Structure", try model.tryGetName(SmithyId.of("test.aggregate#Structure")));
    try testing.expectEqual(.string, model.getShape(SmithyId.of("test.aggregate#Structure$stringMember")));

    try testing.expect(model.hasTrait(
        SmithyId.of("test.aggregate#Structure$stringMember"),
        SmithyId.of("test.trait#Void"),
    ));
    try testing.expectEqualStrings(
        "stringMember",
        try model.tryGetName(SmithyId.of("test.aggregate#Structure$stringMember")),
    );
    try testing.expectEqual(108, model.getTrait(
        i64,
        SmithyId.of("test.aggregate#Structure$stringMember"),
        SmithyId.of("test.trait#Int"),
    ));

    try testing.expectEqual(
        .integer,
        model.getShape(SmithyId.of("test.aggregate#Structure$numberMember")),
    );
    // The traits merged with external `apply` traits.
    try testing.expect(model.hasTrait(
        SmithyId.of("test.aggregate#Structure$numberMember"),
        SmithyId.of("test.trait#Void"),
    ));
    try testing.expectEqualStrings(
        "numberMember",
        try model.tryGetName(SmithyId.of("test.aggregate#Structure$numberMember")),
    );
    try testing.expectEqual(108, model.getTrait(
        i64,
        SmithyId.of("test.aggregate#Structure$numberMember"),
        SmithyId.of("test.trait#Int"),
    ));

    try testing.expectEqualDeep(JsonReader.Value{ .boolean = false }, model.getTrait(
        JsonReader.Value,
        SmithyId.of("test.aggregate#Structure$primitiveBool"),
        trt_refine.Default.id,
    ));
    try testing.expectEqualDeep(JsonReader.Value{ .integer = 0 }, model.getTrait(
        JsonReader.Value,
        SmithyId.of("test.aggregate#Structure$primitiveByte"),
        trt_refine.Default.id,
    ));
    try testing.expectEqualDeep(JsonReader.Value{ .integer = 0 }, model.getTrait(
        JsonReader.Value,
        SmithyId.of("test.aggregate#Structure$primitiveShort"),
        trt_refine.Default.id,
    ));
    try testing.expectEqualDeep(JsonReader.Value{ .integer = 0 }, model.getTrait(
        JsonReader.Value,
        SmithyId.of("test.aggregate#Structure$primitiveInt"),
        trt_refine.Default.id,
    ));
    try testing.expectEqualDeep(JsonReader.Value{ .integer = 0 }, model.getTrait(
        JsonReader.Value,
        SmithyId.of("test.aggregate#Structure$primitiveLong"),
        trt_refine.Default.id,
    ));
    try testing.expectEqualDeep(JsonReader.Value{ .float = 0 }, model.getTrait(
        JsonReader.Value,
        SmithyId.of("test.aggregate#Structure$primitiveFloat"),
        trt_refine.Default.id,
    ));
    try testing.expectEqualDeep(JsonReader.Value{ .float = 0 }, model.getTrait(
        JsonReader.Value,
        SmithyId.of("test.aggregate#Structure$primitiveDouble"),
        trt_refine.Default.id,
    ));

    try testing.expectEqualDeep(
        SmithyType{ .tagged_uinon = &.{
            SmithyId.of("test.aggregate#Union$a"),
            SmithyId.of("test.aggregate#Union$b"),
        } },
        model.getShape(SmithyId.of("test.aggregate#Union")),
    );
    try testing.expectEqualStrings("Union", try model.tryGetName(SmithyId.of("test.aggregate#Union")));
    try testing.expectEqual(.string, model.getShape(SmithyId.of("test.aggregate#Union$a")));
    try testing.expectEqual(.integer, model.getShape(SmithyId.of("test.aggregate#Union$b")));
    try testing.expectEqualStrings("a", try model.tryGetName(SmithyId.of("test.aggregate#Union$a")));
    try testing.expectEqualStrings("b", try model.tryGetName(SmithyId.of("test.aggregate#Union$b")));

    try testing.expectEqualStrings(
        "Operation",
        try model.tryGetName(SmithyId.of("test.serve#Operation")),
    );
    try testing.expectEqualDeep(SmithyType{
        .operation = &.{
            .input = SmithyId.of("test.operation#OperationInput"),
            .output = SmithyId.of("test.operation#OperationOutput"),
            .errors = &.{
                SmithyId.of("test.error#BadRequestError"),
                SmithyId.of("test.error#NotFoundError"),
            },
        },
    }, model.getShape(SmithyId.of("test.serve#Operation")));

    try testing.expectEqualStrings(
        "Resource",
        try model.tryGetName(SmithyId.of("test.serve#Resource")),
    );
    try testing.expectEqualDeep(SmithyType{
        .resource = &.{
            .identifiers = &.{
                .{ .name = "forecastId", .shape = SmithyId.of("smithy.api#String") },
            },
            .properties = &.{
                .{ .name = "prop", .shape = SmithyId.of("test.resource#prop") },
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
    }, model.getShape(SmithyId.of("test.serve#Resource")));

    try testing.expectEqualStrings(
        "Service",
        try model.tryGetName(SmithyId.of("test.serve#Service")),
    );
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
    }, model.getShape(SmithyId.of("test.serve#Service")));
    try testing.expectEqual(
        108,
        model.getTrait(i64, SmithyId.of("test.serve#Service"), SmithyId.of("test.trait#Int")),
    );
    try testing.expectEqual(SmithyId.of("test.serve#Service"), model.service);
}
