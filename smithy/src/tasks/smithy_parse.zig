const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const pipez = @import("../pipeline/root.zig");
const Task = pipez.Task;
const Delegate = pipez.Delegate;
const syb = @import("../systems/symbols.zig");
const SmithyId = syb.SmithyId;
const SmithyType = syb.SmithyType;
const SmithyMeta = syb.SmithyMeta;
const SymbolsProvider = syb.SymbolsProvider;
const SmithyTaggedValue = syb.SmithyTaggedValue;
const trt = @import("../systems/traits.zig");
const TraitsManager = trt.TraitsManager;
const TraitsProvider = trt.TraitsProvider;
const IssuesBag = @import("../utils/IssuesBag.zig");
const JsonReader = @import("../utils/JsonReader.zig");
const trt_refine = @import("../traits/refine.zig");
const ScopeTag = @import("smithy.zig").ScopeTag;

pub const ParsePolicy = struct {
    property: IssuesBag.PolicyResolution = .abort,
    trait: IssuesBag.PolicyResolution = .abort,
};

pub const ServiceParse = Task.Define("Smithy Service Parse", serviceParseTask, .{
    .injects = &.{ TraitsManager, IssuesBag },
});
fn serviceParseTask(
    self: *const Delegate,
    traits_manager: *TraitsManager,
    issues: *IssuesBag,
    json_reader: *JsonReader,
) anyerror!Model {
    const policy = self.readValue(ParsePolicy, ScopeTag.parse_policy) orelse ParsePolicy{};

    var model = Model.init(self.alloc());
    errdefer model.deinit();

    var parser = JsonParser{
        .arena = self.alloc(),
        .traits_manager = traits_manager,
        .policy = policy,
        .issues = issues,
        .reader = json_reader,
        .model = &model,
    };
    try parser.parse();

    return model;
}

/// Parse raw [Smithy JSON AST](https://smithy.io/2.0/spec/json-ast.html) into a
/// collection of Smithy symbols;
///
/// `arena` is used to store the parsed symbols and must be retained as long as
/// they are needed.
/// `json_reader` may be disposed immediately after calling this.
const JsonParser = struct {
    arena: Allocator,
    policy: ParsePolicy,
    traits_manager: *const TraitsManager,
    reader: *JsonReader,
    issues: *IssuesBag,
    model: *Model,

    const Context = struct {
        name: ?[]const u8 = null,
        id: SmithyId = SmithyId.NULL,
        target: Target = .none,

        pub const Target = union(enum) {
            none,
            service: *syb.SmithyService,
            resource: *syb.SmithyResource,
            operation: *syb.SmithyOperation,
            id_list: *std.ArrayListUnmanaged(SmithyId),
            ref_map: *std.ArrayListUnmanaged(syb.SmithyRefMapValue),
            meta,
            meta_list: *std.ArrayListUnmanaged(SmithyMeta),
            meta_map: *std.ArrayListUnmanaged(SmithyMeta.Pair),
        };
    };

    pub fn parse(self: *JsonParser) !void {
        try self.parseScope(.object, parseProp, .{});
        try self.reader.nextDocumentEnd();
    }

    fn parseScope(
        self: *JsonParser,
        comptime scope: JsonReader.Scope,
        comptime parseFn: JsonReader.NextScopeFn(*JsonParser, Context, scope),
        ctx: Context,
    ) !void {
        try self.reader.nextScope(*JsonParser, Context, scope, parseFn, self, ctx);
    }

    fn parseProp(self: *JsonParser, prop_name: []const u8, ctx: Context) !void {
        switch (syb.SmithyProperty.of(prop_name)) {
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

    fn parseMember(self: *JsonParser, prop_name: []const u8, ctx: Context) !void {
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
        self: *JsonParser,
        target: anytype,
        comptime field: []const u8,
        comptime map: bool,
        parsFn: JsonReader.NextScopeFn(*JsonParser, Context, if (map) .object else .array),
    ) !void {
        var list = std.ArrayListUnmanaged(if (map) syb.SmithyRefMapValue else SmithyId){};
        errdefer list.deinit(self.arena);
        if (map)
            try self.parseScope(.object, parsFn, .{ .target = .{ .ref_map = &list } })
        else
            try self.parseScope(.array, parsFn, .{ .target = .{ .id_list = &list } });
        @field(target, field) = try list.toOwnedSlice(self.arena);
    }

    fn parseShapeRefItem(self: *JsonParser, ctx: Context) !void {
        try ctx.target.id_list.append(self.arena, try self.parseShapeRef());
    }

    /// `"forecastId": { "target": "smithy.api#String" }`
    fn parseShapeRefMapFrom(self: *JsonParser, prop: []const u8, ctx: Context) !void {
        const shape = try self.parseShapeRef();
        const name = try self.arena.dupe(u8, prop);
        try ctx.target.ref_map.append(self.arena, .{ .name = name, .shape = shape });
    }

    /// `"foo.example#Widget": "FooWidget"`
    fn parseShapeRefMapTo(self: *JsonParser, prop: []const u8, ctx: Context) !void {
        const shape = SmithyId.of(prop);
        const name = try self.arena.dupe(u8, try self.reader.nextString());
        try ctx.target.ref_map.append(self.arena, .{ .name = name, .shape = shape });
    }

    fn parseShapeRefField(self: *JsonParser, target: anytype, comptime field: []const u8) !void {
        @field(target, field) = try self.parseShapeRef();
    }

    /// An AST shape reference is an object with only a `target` property that maps
    /// to an absolute shape ID.
    ///
    /// [Smithy Spec](https://smithy.io/2.0/spec/json-ast.html#ast-shape-reference)
    fn parseShapeRef(self: *JsonParser) !SmithyId {
        try self.reader.nextObjectBegin();
        try self.reader.nextStringEql("target");
        const shape_ref = SmithyId.of(try self.reader.nextString());
        try self.reader.nextObjectEnd();
        return shape_ref;
    }

    fn parseMixins(self: *JsonParser, parent_id: SmithyId) !void {
        var mixins = std.ArrayListUnmanaged(SmithyId){};
        errdefer mixins.deinit(self.arena);
        try self.parseScope(.array, parseShapeRefItem, .{
            .target = .{ .id_list = &mixins },
        });
        const slice = try mixins.toOwnedSlice(self.arena);
        try self.model.putMixins(parent_id, slice);
    }

    fn parseTraits(self: *JsonParser, parent_name: []const u8, parent_id: SmithyId) !void {
        var traits: std.ArrayListUnmanaged(syb.SmithyTaggedValue) = .{};
        errdefer traits.deinit(self.arena);
        try self.reader.nextObjectBegin();
        while (try self.reader.peek() == .string) {
            const trait_name = try self.reader.nextString();
            const trait_id = SmithyId.of(trait_name);
            if (self.traits_manager.parse(trait_id, self.arena, self.reader)) |value| {
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

        const slice = try traits.toOwnedSlice(self.arena);
        if (try self.model.putTraits(parent_id, slice)) {
            self.arena.free(slice);
        }
    }

    fn parseShape(self: *JsonParser, shape_name: []const u8, _: Context) !void {
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
                const ptr = try self.arena.create(syb.SmithyService);
                ptr.* = mem.zeroInit(syb.SmithyService, .{});
                break :blk ptr;
            } },
            .resource => .{ .resource = blk: {
                const ptr = try self.arena.create(syb.SmithyResource);
                ptr.* = mem.zeroInit(syb.SmithyResource, .{});
                break :blk ptr;
            } },
            .operation => .{ .operation = blk: {
                const ptr = try self.arena.create(syb.SmithyOperation);
                ptr.* = mem.zeroInit(syb.SmithyOperation, .{});
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

    fn putShape(self: *JsonParser, id: SmithyId, type_id: SmithyId, name: []const u8, target: Context.Target) !void {
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
                    const traits = try self.arena.alloc(syb.SmithyTaggedValue, 1);
                    traits[0] = .{
                        .id = trt_refine.Default.id,
                        .value = switch (t) {
                            .boolean => &Primitive.boolean,
                            .byte, .short, .integer, .long => &Primitive.int,
                            .float, .double => &Primitive.float,
                            else => unreachable,
                        },
                    };
                    if (try self.model.putTraits(id, traits)) self.arena.free(traits);
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
                    self.model.service_id = id;
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
        try self.model.putShape(id, smithy_type);
        if (is_named) try self.putName(id, .{ .absolute = name });
    }

    const Name = union(enum) { member: []const u8, absolute: []const u8 };
    fn putName(self: *JsonParser, id: SmithyId, name: Name) !void {
        const part = switch (name) {
            .member => |s| s,
            .absolute => |s| blk: {
                const split = mem.indexOfScalar(u8, s, '#');
                break :blk if (split) |i| s[i + 1 .. s.len] else s;
            },
        };
        try self.model.putName(id, try self.arena.dupe(u8, part));
    }

    fn parseMetaList(self: *JsonParser, ctx: Context) !void {
        try ctx.target.meta_list.append(self.arena, try self.parseMetaValue());
    }

    fn parseMetaMap(self: *JsonParser, meta_name: []const u8, ctx: Context) !void {
        const meta_id = SmithyId.of(meta_name);
        const value = try self.parseMetaValue();
        switch (ctx.target) {
            .meta => try self.model.putMeta(meta_id, value),
            .meta_map => |m| try m.append(self.arena, .{ .key = meta_id, .value = value }),
            else => unreachable,
        }
    }

    fn parseMetaValue(self: *JsonParser) !SmithyMeta {
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

    fn validateSmithyVersion(self: *JsonParser) !void {
        const version = try self.reader.nextString();
        const valid = mem.eql(u8, "2.0", version) or mem.eql(u8, "2", version);
        if (!valid) return error.InvalidVersion;
    }
};

test "parseJson" {
    const Traits = struct {
        fn parseInt(allocator: Allocator, reader: *JsonReader) !*const anyopaque {
            const value = try reader.nextInteger();
            const ptr = try allocator.create(i64);
            ptr.* = value;
            return ptr;
        }
    };

    var tester = try pipez.PipelineTester.init(.{});
    defer tester.deinit();

    var issues = IssuesBag.init(test_alloc);
    defer issues.deinit();
    _ = try tester.provideService(&issues, null);

    var traits = TraitsManager{};
    defer traits.deinit(test_alloc);
    _ = try tester.provideService(&traits, null);
    try traits.registerAll(test_alloc, &.{
        .{ SmithyId.of("test.trait#Void"), null },
        .{ SmithyId.of("test.trait#Int"), Traits.parseInt },
        .{ trt_refine.EnumValue.id, trt_refine.EnumValue.parse },
    });

    try tester.defineValue(ParsePolicy, ScopeTag.parse_policy, ParsePolicy{
        .property = .skip,
        .trait = .skip,
    });

    var input_arena = std.heap.ArenaAllocator.init(test_alloc);
    errdefer input_arena.deinit();
    var reader = try JsonReader.initFixed(
        input_arena.allocator(),
        @embedFile("../testing/shapes.json"),
    );
    errdefer reader.deinit();

    const model = try tester.runTask(ServiceParse, .{&reader});

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

    try model.expectMeta(SmithyId.of("nul"), .null);
    try model.expectMeta(SmithyId.of("bol"), .{ .boolean = true });
    try model.expectMeta(SmithyId.of("int"), .{ .integer = 108 });
    try model.expectMeta(SmithyId.of("flt"), .{ .float = 1.08 });
    try model.expectMeta(SmithyId.of("str"), .{ .string = "foo" });
    try model.expectMeta(SmithyId.of("lst"), .{
        .list = &.{ .{ .integer = 108 }, .{ .integer = 109 } },
    });
    try model.expectMeta(SmithyId.of("map"), .{
        .map = &.{.{ .key = SmithyId.of("key"), .value = .{ .integer = 108 } }},
    });

    //
    // Shapes
    //

    try model.expectShape(SmithyId.of("test.simple#Blob"), .blob);
    try model.expectHasTrait(
        SmithyId.of("test.simple#Blob"),
        SmithyId.of("test.trait#Void"),
    );

    try model.expectShape(SmithyId.of("test.simple#Boolean"), .boolean);
    try model.expectMixins(SmithyId.of("test.simple#Boolean"), &.{
        SmithyId.of("test.mixin#Mixin"),
    });

    try model.expectShape(SmithyId.of("test.simple#Document"), .document);
    try model.expectShape(SmithyId.of("test.simple#String"), .string);
    try model.expectShape(SmithyId.of("test.simple#Byte"), .byte);
    try model.expectShape(SmithyId.of("test.simple#Short"), .short);
    try model.expectShape(SmithyId.of("test.simple#Integer"), .integer);
    try model.expectShape(SmithyId.of("test.simple#Long"), .long);
    try model.expectShape(SmithyId.of("test.simple#Float"), .float);
    try model.expectShape(SmithyId.of("test.simple#Double"), .double);
    try model.expectShape(SmithyId.of("test.simple#BigInteger"), .big_integer);
    try model.expectShape(SmithyId.of("test.simple#BigDecimal"), .big_decimal);
    try model.expectShape(SmithyId.of("test.simple#Timestamp"), .timestamp);

    const enum_foo = SmithyId.of("test.simple#Enum$FOO");
    try model.expectShape(SmithyId.of("test.simple#Enum"), SmithyType{
        .str_enum = &.{enum_foo},
    });
    try model.expectShape(enum_foo, .unit);
    try model.expectTrait(enum_foo, trt_refine.EnumValue.id, trt_refine.EnumValue.Val, .{
        .string = "foo",
    });
    try model.expectName(SmithyId.of("test.simple#Enum"), "Enum");
    try model.expectName(enum_foo, "FOO");

    const inum_foo = SmithyId.of("test.simple#IntEnum$FOO");
    try model.expectShape(SmithyId.of("test.simple#IntEnum"), .{
        .int_enum = &.{inum_foo},
    });
    try model.expectShape(inum_foo, .unit);
    try model.expectTrait(inum_foo, trt_refine.EnumValue.id, trt_refine.EnumValue.Val, .{
        .integer = 1,
    });
    try model.expectName(SmithyId.of("test.simple#IntEnum"), "IntEnum");
    try model.expectName(inum_foo, "FOO");

    try model.expectShape(SmithyId.of("test.aggregate#List"), .{
        .list = SmithyId.of("test.aggregate#List$member"),
    });
    try model.expectShape(SmithyId.of("test.aggregate#List$member"), .string);
    try model.expectHasTrait(
        SmithyId.of("test.aggregate#List$member"),
        SmithyId.of("test.trait#Void"),
    );

    try model.expectShape(SmithyId.of("test.aggregate#Map"), .{
        .map = .{
            SmithyId.of("test.aggregate#Map$key"),
            SmithyId.of("test.aggregate#Map$value"),
        },
    });
    try model.expectShape(SmithyId.of("test.aggregate#Map$key"), .string);
    try model.expectShape(SmithyId.of("test.aggregate#Map$value"), .integer);

    try model.expectShape(SmithyId.of("test.aggregate#Structure"), .{
        .structure = &.{
            SmithyId.of("test.aggregate#Structure$stringMember"),
            SmithyId.of("test.aggregate#Structure$numberMember"),
            SmithyId.of("test.aggregate#Structure$primitiveBool"),
            SmithyId.of("test.aggregate#Structure$primitiveByte"),
            SmithyId.of("test.aggregate#Structure$primitiveShort"),
            SmithyId.of("test.aggregate#Structure$primitiveInt"),
            SmithyId.of("test.aggregate#Structure$primitiveLong"),
            SmithyId.of("test.aggregate#Structure$primitiveFloat"),
            SmithyId.of("test.aggregate#Structure$primitiveDouble"),
        },
    });
    try model.expectName(SmithyId.of("test.aggregate#Structure"), "Structure");
    try model.expectShape(SmithyId.of("test.aggregate#Structure$stringMember"), .string);

    try model.expectHasTrait(
        SmithyId.of("test.aggregate#Structure$stringMember"),
        SmithyId.of("test.trait#Void"),
    );
    try model.expectName(SmithyId.of("test.aggregate#Structure$stringMember"), "stringMember");
    try model.expectTrait(
        SmithyId.of("test.aggregate#Structure$stringMember"),
        SmithyId.of("test.trait#Int"),
        i64,
        108,
    );

    try model.expectShape(SmithyId.of("test.aggregate#Structure$numberMember"), .integer);
    // The traits merged with external `apply` traits.
    try model.expectHasTrait(
        SmithyId.of("test.aggregate#Structure$numberMember"),
        SmithyId.of("test.trait#Void"),
    );
    try model.expectName(SmithyId.of("test.aggregate#Structure$numberMember"), "numberMember");
    try model.expectTrait(
        SmithyId.of("test.aggregate#Structure$numberMember"),
        SmithyId.of("test.trait#Int"),
        i64,
        108,
    );

    try model.expectTrait(
        SmithyId.of("test.aggregate#Structure$primitiveBool"),
        trt_refine.Default.id,
        JsonReader.Value,
        JsonReader.Value{ .boolean = false },
    );
    try model.expectTrait(
        SmithyId.of("test.aggregate#Structure$primitiveByte"),
        trt_refine.Default.id,
        JsonReader.Value,
        JsonReader.Value{ .integer = 0 },
    );
    try model.expectTrait(
        SmithyId.of("test.aggregate#Structure$primitiveShort"),
        trt_refine.Default.id,
        JsonReader.Value,
        JsonReader.Value{ .integer = 0 },
    );
    try model.expectTrait(
        SmithyId.of("test.aggregate#Structure$primitiveInt"),
        trt_refine.Default.id,
        JsonReader.Value,
        JsonReader.Value{ .integer = 0 },
    );
    try model.expectTrait(
        SmithyId.of("test.aggregate#Structure$primitiveLong"),
        trt_refine.Default.id,
        JsonReader.Value,
        JsonReader.Value{ .integer = 0 },
    );
    try model.expectTrait(
        SmithyId.of("test.aggregate#Structure$primitiveFloat"),
        trt_refine.Default.id,
        JsonReader.Value,
        JsonReader.Value{ .float = 0 },
    );
    try model.expectTrait(
        SmithyId.of("test.aggregate#Structure$primitiveDouble"),
        trt_refine.Default.id,
        JsonReader.Value,
        JsonReader.Value{ .float = 0 },
    );

    try model.expectShape(SmithyId.of("test.aggregate#Union"), .{
        .tagged_uinon = &.{
            SmithyId.of("test.aggregate#Union$a"),
            SmithyId.of("test.aggregate#Union$b"),
        },
    });
    try model.expectName(SmithyId.of("test.aggregate#Union"), "Union");
    try model.expectShape(SmithyId.of("test.aggregate#Union$a"), .string);
    try model.expectShape(SmithyId.of("test.aggregate#Union$b"), .integer);
    try model.expectName(SmithyId.of("test.aggregate#Union$a"), "a");
    try model.expectName(SmithyId.of("test.aggregate#Union$b"), "b");

    try model.expectName(SmithyId.of("test.serve#Operation"), "Operation");
    try model.expectShape(SmithyId.of("test.serve#Operation"), .{
        .operation = &.{
            .input = SmithyId.of("test.operation#OperationInput"),
            .output = SmithyId.of("test.operation#OperationOutput"),
            .errors = &.{
                SmithyId.of("test.error#BadRequestError"),
                SmithyId.of("test.error#NotFoundError"),
            },
        },
    });

    try model.expectName(SmithyId.of("test.serve#Resource"), "Resource");
    try model.expectShape(SmithyId.of("test.serve#Resource"), .{
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
    });

    try model.expectName(SmithyId.of("test.serve#Service"), "Service");
    try model.expectShape(SmithyId.of("test.serve#Service"), .{
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
    });
    try model.expectTrait(
        SmithyId.of("test.serve#Service"),
        SmithyId.of("test.trait#Int"),
        i64,
        108,
    );
    try testing.expectEqual(SmithyId.of("test.serve#Service"), model.service_id);
}

/// Raw symbols (shapes and metadata) of a Smithy model.
pub const Model = struct {
    allocator: Allocator,
    service_id: SmithyId = SmithyId.NULL,
    meta: std.AutoHashMapUnmanaged(SmithyId, SmithyMeta) = .{},
    shapes: std.AutoHashMapUnmanaged(SmithyId, SmithyType) = .{},
    names: std.AutoHashMapUnmanaged(SmithyId, []const u8) = .{},
    traits: std.AutoHashMapUnmanaged(SmithyId, []const SmithyTaggedValue) = .{},
    mixins: std.AutoHashMapUnmanaged(SmithyId, []const SmithyId) = .{},

    pub fn init(allocator: Allocator) Model {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Model) void {
        self.meta.deinit(self.allocator);
        self.shapes.deinit(self.allocator);
        self.traits.deinit(self.allocator);
        self.mixins.deinit(self.allocator);
        self.names.deinit(self.allocator);
    }

    pub fn consume(self: *Model, arena: Allocator) !syb.SymbolsProvider {
        var dupe_meta = try self.meta.clone(arena);
        errdefer dupe_meta.deinit(arena);

        var dupe_shapes = try self.shapes.clone(arena);
        errdefer dupe_shapes.deinit(arena);

        var dupe_names = try self.names.clone(arena);
        errdefer dupe_names.deinit(arena);

        var dupe_traits = try self.traits.clone(arena);
        errdefer dupe_traits.deinit(arena);

        const dupe_mixins = try self.mixins.clone(arena);

        defer self.deinit();
        return .{
            .arena = arena,
            .service_id = self.service_id,
            .model_meta = dupe_meta,
            .model_shapes = dupe_shapes,
            .model_names = dupe_names,
            .model_traits = dupe_traits,
            .model_mixins = dupe_mixins,
        };
    }

    pub fn putMeta(self: *Model, key: SmithyId, value: SmithyMeta) !void {
        try self.meta.put(self.allocator, key, value);
    }

    pub fn putShape(self: *Model, id: SmithyId, shape: SmithyType) !void {
        try self.shapes.put(self.allocator, id, shape);
    }

    pub fn putName(self: *Model, id: SmithyId, name: []const u8) !void {
        try self.names.put(self.allocator, id, name);
    }

    /// Returns `true` if expanded an existing traits list.
    pub fn putTraits(self: *Model, id: SmithyId, traits: []const syb.SmithyTaggedValue) !bool {
        const result = try self.traits.getOrPut(self.allocator, id);
        if (!result.found_existing) {
            result.value_ptr.* = traits;
            return false;
        }

        const current = result.value_ptr.*;
        const all = try self.allocator.alloc(SmithyTaggedValue, current.len + traits.len);
        @memcpy(all[0..current.len], current);
        @memcpy(all[current.len..][0..traits.len], traits);
        self.allocator.free(current);
        result.value_ptr.* = all;
        return true;
    }

    pub fn putMixins(self: *Model, id: SmithyId, mixins: []const SmithyId) !void {
        try self.mixins.put(self.allocator, id, mixins);
    }

    pub fn expectMeta(self: Model, id: SmithyId, expected: SmithyMeta) !void {
        try testing.expectEqualDeep(expected, self.meta.get(id).?);
    }

    pub fn expectShape(self: Model, id: SmithyId, expected: SmithyType) !void {
        try testing.expectEqualDeep(expected, self.shapes.get(id).?);
    }

    pub fn expectName(self: Model, id: SmithyId, expected: []const u8) !void {
        try testing.expectEqualStrings(expected, self.names.get(id).?);
    }

    pub fn expectHasTrait(self: Model, shape_id: SmithyId, trait_id: SmithyId) !void {
        const values = self.traits.get(shape_id) orelse return error.TraitsNotFound;
        const provider = TraitsProvider{ .values = values };
        try testing.expect(provider.has(trait_id));
    }

    pub fn expectTrait(
        self: Model,
        shape_id: SmithyId,
        trait_id: SmithyId,
        comptime T: type,
        expected: T,
    ) !void {
        const values = self.traits.get(shape_id) orelse return error.TraitsNotFound;
        const provider = TraitsProvider{ .values = values };
        const actual = provider.get(T, trait_id) orelse return error.ValueNotFound;
        try testing.expectEqualDeep(expected, actual);
    }

    pub fn expectMixins(self: Model, id: SmithyId, expected: []const SmithyId) !void {
        try testing.expectEqualDeep(expected, self.mixins.get(id));
    }
};

test "Model.putTraits" {
    const foo = "Foo";
    const bar = "Bar";
    const baz = "Baz";

    var model = Model.init(test_alloc);
    defer model.deinit();

    const traits = try test_alloc.alloc(SmithyTaggedValue, 2);
    traits[0] = .{ .id = SmithyId.of("Foo"), .value = foo };
    traits[1] = .{ .id = SmithyId.of("Bar"), .value = bar };
    {
        errdefer test_alloc.free(traits);
        try testing.expectEqual(false, try model.putTraits(SmithyId.of("Traits"), traits));
        try testing.expectEqualDeep(&[_]SmithyTaggedValue{
            .{ .id = SmithyId.of("Foo"), .value = foo },
            .{ .id = SmithyId.of("Bar"), .value = bar },
        }, model.traits.get(SmithyId.of("Traits")));

        try testing.expectEqual(true, try model.putTraits(
            SmithyId.of("Traits"),
            &.{.{ .id = SmithyId.of("Baz"), .value = baz }},
        ));
    }
    defer test_alloc.free(model.traits.get(SmithyId.of("Traits")).?);

    try testing.expectEqualDeep(&[_]SmithyTaggedValue{
        .{ .id = SmithyId.of("Foo"), .value = foo },
        .{ .id = SmithyId.of("Bar"), .value = bar },
        .{ .id = SmithyId.of("Baz"), .value = baz },
    }, model.traits.get(SmithyId.of("Traits")));
}
