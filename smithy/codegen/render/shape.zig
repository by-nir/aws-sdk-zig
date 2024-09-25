const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const jobz = @import("jobz");
const Task = jobz.Task;
const Delegate = jobz.Delegate;
const md = @import("razdaz").md;
const zig = @import("razdaz").zig;
const ExprBuild = zig.ExprBuild;
const BlockBuild = zig.BlockBuild;
const ContainerBuild = zig.ContainerBuild;
const Writer = @import("razdaz").CodegenWriter;
const clnt = @import("client.zig");
const mdl = @import("../model.zig");
const SmithyId = mdl.SmithyId;
const SmithyType = mdl.SmithyType;
const cfg = @import("../config.zig");
const ScopeTag = @import("../pipeline.zig").ScopeTag;
const isu = @import("../systems/issues.zig");
const IssuesBag = isu.IssuesBag;
const SymbolsProvider = @import("../systems/SymbolsProvider.zig");
const name_util = @import("../utils/names.zig");
const JsonValue = @import("../utils/JsonReader.zig").Value;
const trt_docs = @import("../traits/docs.zig");
const trt_refine = @import("../traits/refine.zig");
const trt_constr = @import("../traits/constraint.zig");
const test_symbols = @import("../testing/symbols.zig");

pub const ShapeOptions = struct {
    /// Override the struct’s identifier.
    identifier: ?[]const u8 = null,
    /// Use the specified scope when referencing named shapes.
    scope: ?[]const u8 = null,
    /// Special output struct
    is_output: bool = false,
};

pub fn writeShapeDecleration(
    arena: Allocator,
    symbols: *SymbolsProvider,
    bld: *ContainerBuild,
    id: SmithyId,
    options: ShapeOptions,
) !void {
    switch (try symbols.getShape(id)) {
        .operation, .resource, .service, .list, .map => unreachable,
        .trt_enum => try writeTraitEnumShape(arena, symbols, bld, id, options),
        .str_enum => |m| try writeStrEnumShape(arena, symbols, bld, id, m, options),
        .int_enum => |m| try writeIntEnumShape(symbols, bld, id, m, options),
        .tagged_union => |m| try writeUnionShape(symbols, bld, id, m, options),
        .structure => |m| try writeStructShape(symbols, bld, id, m, options),
        else => return error.UndeclerableShape,
    }
}

fn writeStrEnumShape(
    arena: Allocator,
    symbols: *SymbolsProvider,
    bld: *ContainerBuild,
    id: SmithyId,
    members: []const SmithyId,
    options: ShapeOptions,
) !void {
    var list = try EnumList.initCapacity(arena, members.len);
    defer list.deinit();

    for (members) |m| {
        const value = trt_refine.EnumValue.get(symbols, m);
        const value_str = if (value) |v| v.string else try symbols.getShapeName(m, .scream, .{});
        const field_name = try symbols.getShapeName(m, .snake, .{});
        list.appendAssumeCapacity(.{
            .value = value_str,
            .field = field_name,
        });
    }

    try writeEnumShape(arena, symbols, bld, id, list.items, options);
}

test writeStrEnumShape {
    try shapeTester(.enums_str, SmithyId.of("test#Enum"), .{},
        \\pub const Enum = union(enum) {
        \\    /// Used for backwards compatibility when adding new values.
        \\    UNKNOWN: []const u8,
        \\    foo_bar,
        \\    baz_qux,
        \\
        \\    const parse_map = std.StaticStringMap(@This()).initComptime(.{ .{ "FOO_BAR", .foo_bar }, .{ "baz$qux", .baz_qux } });
        \\
        \\    pub fn parse(value: []const u8) @This() {
        \\        return parse_map.get(value) orelse .{ .UNKNOWN = value };
        \\    }
        \\
        \\    pub fn toString(self: @This()) []const u8 {
        \\        return switch (self) {
        \\            .UNKNOWN => |s| s,
        \\            .foo_bar => "FOO_BAR",
        \\            .baz_qux => "baz$qux",
        \\        };
        \\    }
        \\};
    );
}

fn writeTraitEnumShape(
    arena: Allocator,
    symbols: *SymbolsProvider,
    bld: *ContainerBuild,
    id: SmithyId,
    options: ShapeOptions,
) !void {
    const members = trt_constr.Enum.get(symbols, id) orelse unreachable;
    var list = try EnumList.initCapacity(arena, members.len);
    defer list.deinit();

    for (members) |m| {
        list.appendAssumeCapacity(.{
            .value = m.value,
            .field = try name_util.formatCase(arena, .snake, m.name orelse m.value),
        });
    }

    try writeEnumShape(arena, symbols, bld, id, list.items, options);
}

test writeTraitEnumShape {
    try shapeTester(.enums_str, SmithyId.of("test#EnumTrt"), .{},
        \\pub const EnumTrt = union(enum) {
        \\    /// Used for backwards compatibility when adding new values.
        \\    UNKNOWN: []const u8,
        \\    foo_bar,
        \\    baz_qux,
        \\
        \\    const parse_map = std.StaticStringMap(@This()).initComptime(.{ .{ "FOO_BAR", .foo_bar }, .{ "baz$qux", .baz_qux } });
        \\
        \\    pub fn parse(value: []const u8) @This() {
        \\        return parse_map.get(value) orelse .{ .UNKNOWN = value };
        \\    }
        \\
        \\    pub fn toString(self: @This()) []const u8 {
        \\        return switch (self) {
        \\            .UNKNOWN => |s| s,
        \\            .foo_bar => "FOO_BAR",
        \\            .baz_qux => "baz$qux",
        \\        };
        \\    }
        \\};
    );
}

const EnumList = std.ArrayList(StrEnumMember);
const StrEnumMember = struct {
    value: []const u8,
    field: []const u8,

    pub fn format(self: StrEnumMember, writer: *Writer) !void {
        try writer.appendFmt(".{{ \"{s}\", .{s} }}", .{ self.value, self.field });
    }

    pub fn asLiteralExpr(self: StrEnumMember, bld: *ContainerBuild) ExprBuild {
        return bld.x.structLiteral(
            null,
            &.{ bld.x.valueOf(self.value), bld.x.dot().raw(self.field) },
        );
    }
};

fn writeEnumShape(
    arena: Allocator,
    symbols: *SymbolsProvider,
    bld: *ContainerBuild,
    id: SmithyId,
    members: []const StrEnumMember,
    options: ShapeOptions,
) !void {
    const context = .{ .arena = arena, .members = members, .options = options };
    const Closures = struct {
        fn shape(ctx: @TypeOf(context), b: *ContainerBuild) !void {
            var literals = std.ArrayList(ExprBuild).init(ctx.arena);
            defer literals.deinit();

            try b.comment(.doc, "Used for backwards compatibility when adding new values.");
            try b.field("UNKNOWN").typing(b.x.typeOf([]const u8)).end();
            for (ctx.members) |m| {
                try b.field(m.field).end();
                try literals.append(m.asLiteralExpr(b));
            }

            try b.constant("parse_map").assign(
                b.x.raw("std.StaticStringMap(@This())").dot().call("initComptime", &.{
                    b.x.structLiteral(null, literals.items),
                }),
            );

            try b.public().function("parse")
                .arg("value", b.x.typeOf([]const u8))
                .returns(b.x.This())
                .body(parseFunc);

            try b.public().function("toString")
                .arg("self", b.x.This())
                .returns(b.x.typeOf([]const u8))
                .bodyWith(ctx, toStringFunc);
        }

        fn deinitFunc(b: *BlockBuild) !void {
            try b.@"if"(b.x.id("self").op(.eql).dot().id("UNKNOWN"))
                .body(b.x.id(cfg.alloc_param).dot().call("free", &.{b.x.raw("self.UNKNOWN")}))
                .end();
        }

        fn parseFunc(b: *BlockBuild) !void {
            try b.returns().raw("parse_map.get(value) orelse .{ .UNKNOWN = value }").end();
        }

        fn toStringFunc(ctx: @TypeOf(context), b: *BlockBuild) !void {
            try b.returns().switchWith(b.x.raw("self"), ctx, toStringSwitch).end();
        }

        fn toStringSwitch(ctx: @TypeOf(context), b: *zig.SwitchBuild) !void {
            try b.branch().case(b.x.valueOf(.UNKNOWN)).capture("s").body(b.x.raw("s"));
            for (ctx.members) |m| {
                try b.branch().case(b.x.dot().raw(m.field)).body(b.x.valueOf(m.value));
            }
        }
    };

    const shape_name = options.identifier orelse try symbols.getShapeName(id, .pascal, .{});
    try writeDocComment(symbols, bld, id, false);
    try bld.public().constant(shape_name).assign(
        bld.x.@"union"().bodyWith(context, Closures.shape),
    );
}

fn writeIntEnumShape(
    symbols: *SymbolsProvider,
    bld: *ContainerBuild,
    id: SmithyId,
    members: []const SmithyId,
    options: ShapeOptions,
) !void {
    const context = .{ .symbols = symbols, .members = members };
    const Closures = struct {
        fn shape(ctx: @TypeOf(context), b: *ContainerBuild) !void {
            for (ctx.members) |m| {
                const shape_name = try ctx.symbols.getShapeName(m, .snake, .{});
                const shape_value = trt_refine.EnumValue.get(ctx.symbols, m).?.integer;
                try b.field(shape_name).assign(b.x.valueOf(shape_value));
            }
            try b.comment(.doc, "Used for backwards compatibility when adding new values.");
            try b.field("_").end();
        }
    };

    const shape_name = options.identifier orelse try symbols.getShapeName(id, .pascal, .{});
    try writeDocComment(symbols, bld, id, false);
    try bld.public().constant(shape_name).assign(
        bld.x.@"enum"().backedBy(bld.x.typeOf(i32)).bodyWith(context, Closures.shape),
    );
}

test writeIntEnumShape {
    try shapeTester(.enum_int, SmithyId.of("test#IntEnum"), .{},
        \\/// An **integer-based** enumeration.
        \\pub const IntEnum = enum(i32) {
        \\    foo_bar = 8,
        \\    baz_qux = 9,
        \\    /// Used for backwards compatibility when adding new values.
        \\    _,
        \\};
    );
}

fn writeUnionShape(
    symbols: *SymbolsProvider,
    bld: *ContainerBuild,
    id: SmithyId,
    members: []const SmithyId,
    options: ShapeOptions,
) !void {
    try writeDocComment(symbols, bld, id, false);

    const context = .{ .symbols = symbols, .members = members, .options = options };
    const Closures = struct {
        fn writeContainer(ctx: @TypeOf(context), b: *ContainerBuild) !void {
            var allocated = false;

            for (ctx.members) |m| {
                const type_name = try typeName(ctx.symbols, m, ctx.options.scope);
                const member_name = try ctx.symbols.getShapeName(m, .snake, .{});
                if (type_name.len > 0) {
                    try b.field(member_name).typing(b.x.raw(type_name)).end();
                } else {
                    try b.field(member_name).end();
                }

                if (try isAllocatedType(ctx.symbols, m)) allocated = true;
            }
        }
    };

    const shape_name = options.identifier orelse try symbols.getShapeName(id, .pascal, .{});
    try bld.public().constant(shape_name).assign(
        bld.x.@"union"().bodyWith(context, Closures.writeContainer),
    );
}

test writeUnionShape {
    try shapeTester(.union_str, SmithyId.of("test#Union"), .{},
        \\pub const Union = union(enum) {
        \\    foo,
        \\    bar: i32,
        \\    baz: []const u8,
        \\};
    );
}

fn writeStructShape(
    symbols: *SymbolsProvider,
    bld: *ContainerBuild,
    id: SmithyId,
    members: []const SmithyId,
    options: ShapeOptions,
) !void {
    const is_input = symbols.hasTrait(id, trt_refine.input_id);
    const context = .{ .symbols = symbols, .id = id, .members = members, .is_input = is_input, .options = options };

    const Closures = struct {
        fn writeContainer(ctx: @TypeOf(context), b: *ContainerBuild) !void {
            var allocated = false;

            if (try writeStructShapeMixin(ctx.symbols, b, ctx.is_input, ctx.id, ctx.options.scope)) allocated = true;

            for (ctx.members) |m| {
                try writeStructShapeMember(ctx.symbols, b, ctx.is_input, m, ctx.options.scope);
                if (try isAllocatedType(ctx.symbols, m)) allocated = true;
            }

            if (ctx.options.is_output and allocated) {
                try b.field("arena").typing(b.x.raw("?std.heap.ArenaAllocator")).assign(b.x.valueOf(null));
                try b.public().function("deinit").arg("self", b.x.This()).body(writeOutputDeinit);
            }
        }

        fn writeOutputDeinit(b: *BlockBuild) !void {
            try b.@"if"(b.x.id("self").dot().id("arena"))
                .capture("arena").body(b.x.call("arena.deinit", &.{}))
                .end();
        }
    };

    const shape_name = options.identifier orelse try symbols.getShapeName(id, .pascal, .{});

    try writeDocComment(symbols, bld, id, false);
    try bld.public().constant(shape_name).assign(
        bld.x.@"struct"().bodyWith(context, Closures.writeContainer),
    );
}

fn writeStructShapeMixin(
    symbols: *SymbolsProvider,
    bld: *ContainerBuild,
    is_input: bool,
    id: SmithyId,
    scope: ?[]const u8,
) !bool {
    var allocated = false;

    const mixins = symbols.getMixins(id) orelse return false;
    for (mixins) |mix_id| {
        if (try writeStructShapeMixin(symbols, bld, is_input, mix_id, scope)) allocated = true;

        const mixin = (try symbols.getShape(mix_id)).structure;
        for (mixin) |m| {
            try writeStructShapeMember(symbols, bld, is_input, m, scope);
            if (try isAllocatedType(symbols, m)) allocated = true;
        }
    }

    return allocated;
}

fn writeStructShapeMember(
    symbols: *SymbolsProvider,
    bld: *ContainerBuild,
    is_input: bool,
    id: SmithyId,
    scope: ?[]const u8,
) !void {
    const shape_name = try symbols.getShapeName(id, .snake, .{});
    const is_optional = isStructMemberOptional(symbols, id, is_input);

    var type_expr = bld.x.raw(try typeName(symbols, id, scope));
    if (is_optional) type_expr = bld.x.typeOptional(type_expr);

    try writeDocComment(symbols, bld, id, true);
    const field = bld.field(shape_name).typing(type_expr);
    const assign: ?ExprBuild = blk: {
        if (is_optional) break :blk bld.x.valueOf(null);
        if (trt_refine.Default.get(symbols, id)) |json| {
            break :blk switch (try symbols.getShapeUnwrap(id)) {
                .boolean => bld.x.valueOf(json.boolean),
                .str_enum, .trt_enum, .string => bld.x.dot().raw(json.string),
                .int_enum => bld.x.call("@enumFromInt", &.{bld.x.valueOf(json.integer)}),
                .byte, .short, .integer, .long => bld.x.valueOf(json.integer),
                .float, .double => bld.x.valueOf(json.float),
                inline .blob, .map, .list, .timestamp, .document => |_, g| {
                    // TODO
                    std.log.warn("Unimplemented default value `{s}`", .{@tagName(g)});
                    unreachable;
                },
                else => unreachable,
            };
        }
        break :blk null;
    };
    if (assign) |a| try field.assign(a) else try field.end();
}

/// https://smithy.io/2.0/spec/aggregate-types.html#structure-member-optionality
pub fn isStructMemberOptional(symbols: *SymbolsProvider, id: SmithyId, is_input: bool) bool {
    if (is_input) return true;

    if (symbols.getTraits(id)) |bag| {
        return bag.has(trt_refine.client_optional_id) or
            !(bag.has(trt_refine.required_id) or bag.has(trt_refine.Default.id));
    }

    return true;
}

test writeStructShape {
    try shapeTester(.structure, SmithyId.of("test#Struct"), .{},
        \\pub const Struct = struct {
        \\    mixed: ?bool = null,
        \\    /// A **struct** member.
        \\    foo_bar: []const u8,
        \\    /// An **integer-based** enumeration.
        \\    baz_qux: IntEnum = @enumFromInt(8),
        \\};
    );
}

pub fn writeDocComment(symbols: *SymbolsProvider, bld: *ContainerBuild, id: SmithyId, target_fallback: bool) !void {
    const docs = trt_docs.Documentation.get(symbols, id) orelse blk: {
        if (!target_fallback) break :blk null;
        const shape = symbols.getShape(id) catch break :blk null;
        break :blk switch (shape) {
            .target => |t| trt_docs.Documentation.get(symbols, t),
            else => null,
        };
    } orelse return;

    try bld.commentMarkdownWith(.doc, md.html.CallbackContext{
        .allocator = symbols.arena,
        .html = docs,
    }, md.html.callback);
}

pub fn writeDocument(x: ExprBuild, json_val: JsonValue) !zig.Expr {
    switch (json_val) {
        .null => return x.valueOf(.null).consume(),
        .array => |t| {
            var list = try std.ArrayList(ExprBuild).initCapacity(x.allocator, t.len);
            for (t) |item| {
                const sub_doc = try writeDocument(x, item);
                list.appendAssumeCapacity(x.fromExpr(sub_doc));
            }
            return x.structLiteral(null, &.{
                x.structAssign("array", x.addressOf().structLiteral(null, try list.toOwnedSlice())),
            }).consume();
        },
        .object => |t| {
            var list = try std.ArrayList(ExprBuild).initCapacity(x.allocator, t.len);
            for (t) |item| {
                const sub_doc = try writeDocument(x, item.value);
                list.appendAssumeCapacity(x.structLiteral(null, &.{
                    x.structAssign("key", x.valueOf(item.key)),
                    x.structAssign("key_alloc", x.valueOf(false)),
                    x.structAssign("document", x.fromExpr(sub_doc)),
                }));
            }
            return x.structLiteral(null, &.{
                x.structAssign("object", x.addressOf().structLiteral(null, try list.toOwnedSlice())),
            }).consume();
        },
        inline else => |t, g| {
            return x.structLiteral(null, &.{x.structAssign(@tagName(g), x.valueOf(t))}).consume();
        },
    }
}

test writeDocument {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    const expr = try writeDocument(.{ .allocator = arena_alloc }, JsonValue{
        .array = &.{
            JsonValue{ .boolean = true },
            JsonValue{ .integer = 108 },
            JsonValue{ .float = 1.08 },
            JsonValue{ .string = "foo" },
            JsonValue{ .object = &.{
                .{ .key = "obj", .value = JsonValue.null },
            } },
        },
    });
    try expr.expect(arena_alloc,
        \\.{.array = &.{
        \\    .{.boolean = true},
        \\    .{.integer = 108},
        \\    .{.float = 1.08},
        \\    .{.string = "foo"},
        \\    .{.object = &.{.{
        \\        .key = "obj",
        \\        .key_alloc = false,
        \\        .document = .null,
        \\    }}},
        \\}}
    );
}

pub const ListType = enum { standard, sparse, set };
pub fn listType(symbols: *const SymbolsProvider, shape_id: SmithyId) ListType {
    if (symbols.hasTrait(shape_id, trt_constr.unique_items_id)) return ListType.set;
    if (symbols.hasTrait(shape_id, trt_refine.sparse_id)) return ListType.sparse;
    return ListType.standard;
}

pub fn typeName(symbols: *SymbolsProvider, id: SmithyId, scoped: ?[]const u8) ![]const u8 {
    switch (id) {
        .str_enum, .int_enum, .list, .map, .structure, .tagged_union, .operation, .resource, .service, .apply => unreachable,
        .document => return error.UnexpectedDocumentShape, // A document’s consumer should parse it into a meaningful type manually
        .unit => return "", // The union type generator assumes a unit is an empty string
        .boolean => return "bool",
        .byte => return "i8",
        .short => return "i16",
        .integer => return "i32",
        .long => return "i64",
        .float => return "f32",
        .double => return "f64",
        .timestamp => return "u64",
        .string, .blob => return "[]const u8",
        .big_integer, .big_decimal => return "[]const u8",
        _ => |shape_id| {
            const shape = symbols.model_shapes.get(id) orelse return error.ShapeNotFound;
            switch (shape) {
                inline .unit,
                .blob,
                .boolean,
                .string,
                .byte,
                .short,
                .integer,
                .long,
                .float,
                .double,
                .big_integer,
                .big_decimal,
                .timestamp,
                .document,
                => |_, g| {
                    const type_id = std.enums.nameCast(SmithyId, g);
                    return typeName(symbols, type_id, scoped);
                },
                .target => |target| return typeName(symbols, target, scoped),
                .list => |target| {
                    const target_type = try typeName(symbols, target, scoped);
                    return switch (listType(symbols, shape_id)) {
                        .standard => std.fmt.allocPrint(symbols.arena, "[]const {s}", .{target_type}),
                        .sparse => std.fmt.allocPrint(symbols.arena, "[]const ?{s}", .{target_type}),
                        .set => std.fmt.allocPrint(symbols.arena, cfg.runtime_scope ++ ".Set({s})", .{target_type}),
                    };
                },
                .map => |targets| {
                    const key_type = try typeName(symbols, targets[0], scoped);
                    const val_type = try typeName(symbols, targets[1], scoped);
                    const optional = if (symbols.hasTrait(shape_id, trt_refine.sparse_id)) "?" else "";
                    const format = cfg.runtime_scope ++ ".Map({s}, {s}{s})";
                    return std.fmt.allocPrint(symbols.arena, format, .{ key_type, optional, val_type });
                },
                else => if (scoped) |scope| {
                    const shape_name = try symbols.getShapeName(shape_id, .pascal, .{});
                    return std.fmt.allocPrint(symbols.arena, "{s}.{s}", .{ scope, shape_name });
                } else {
                    return symbols.getShapeName(shape_id, .pascal, .{});
                },
            }
        },
    }
}

test typeName {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    const foo_id = SmithyId.of("test.simple#Foo");
    var symbols: SymbolsProvider = blk: {
        var names: std.AutoHashMapUnmanaged(SmithyId, []const u8) = .{};
        errdefer names.deinit(arena_alloc);
        try names.put(arena_alloc, foo_id, "Foo");

        var shapes: std.AutoHashMapUnmanaged(SmithyId, SmithyType) = .{};
        errdefer shapes.deinit(arena_alloc);
        try shapes.put(arena_alloc, foo_id, .{ .structure = &.{} });
        try shapes.put(arena_alloc, SmithyId.of("test#List"), .{ .list = foo_id });
        try shapes.put(arena_alloc, SmithyId.of("test#ListMaybe"), .{ .list = foo_id });
        try shapes.put(arena_alloc, SmithyId.of("test#Set"), .{ .list = foo_id });
        try shapes.put(arena_alloc, SmithyId.of("test#Map"), .{ .map = [2]SmithyId{ .string, .integer } });

        var traits: std.AutoHashMapUnmanaged(SmithyId, []const mdl.SmithyTaggedValue) = .{};
        errdefer traits.deinit(arena_alloc);
        try traits.put(arena_alloc, SmithyId.of("test#ListMaybe"), &.{
            .{ .id = trt_refine.sparse_id, .value = null },
        });
        try traits.put(arena_alloc, SmithyId.of("test#Set"), &.{
            .{ .id = trt_constr.unique_items_id, .value = null },
        });

        break :blk .{
            .arena = arena_alloc,
            .service_id = SmithyId.NULL,
            .model_shapes = shapes,
            .model_names = names,
            .model_traits = traits,
        };
    };
    defer symbols.deinit();

    try testing.expectError(error.UnexpectedDocumentShape, typeName(&symbols, SmithyId.document, null));

    try testing.expectEqualStrings("", try typeName(&symbols, .unit, null));
    try testing.expectEqualStrings("bool", try typeName(&symbols, .boolean, null));
    try testing.expectEqualStrings("i8", try typeName(&symbols, .byte, null));
    try testing.expectEqualStrings("i16", try typeName(&symbols, .short, null));
    try testing.expectEqualStrings("i32", try typeName(&symbols, .integer, null));
    try testing.expectEqualStrings("i64", try typeName(&symbols, .long, null));
    try testing.expectEqualStrings("f32", try typeName(&symbols, .float, null));
    try testing.expectEqualStrings("f64", try typeName(&symbols, .double, null));
    try testing.expectEqualStrings("u64", try typeName(&symbols, .timestamp, null));
    try testing.expectEqualStrings("[]const u8", try typeName(&symbols, .blob, null));
    try testing.expectEqualStrings("[]const u8", try typeName(&symbols, .string, null));
    try testing.expectEqualStrings("[]const u8", try typeName(&symbols, .big_integer, null));
    try testing.expectEqualStrings("[]const u8", try typeName(&symbols, .big_decimal, null));

    try testing.expectEqualStrings("Foo", try typeName(&symbols, foo_id, null));
    try testing.expectEqualStrings("types.Foo", try typeName(&symbols, foo_id, "types"));

    try testing.expectEqualStrings("[]const Foo", try typeName(&symbols, SmithyId.of("test#List"), null));
    try testing.expectEqualStrings("[]const ?Foo", try typeName(&symbols, SmithyId.of("test#ListMaybe"), null));
    try testing.expectEqualStrings("smithy.Set(Foo)", try typeName(&symbols, SmithyId.of("test#Set"), null));
    try testing.expectEqualStrings("smithy.Map([]const u8, i32)", try typeName(&symbols, SmithyId.of("test#Map"), null));
}

fn isAllocatedType(symbols: *const SymbolsProvider, id: SmithyId) !bool {
    switch (try symbols.getShapeUnwrap(id)) {
        .target, .operation, .resource, .service => unreachable,
        .blob, .string, .str_enum, .trt_enum, .list, .map => return true,
        .structure, .tagged_union => |members| {
            for (members) |m| {
                if (try isAllocatedType(symbols, m)) return true;
            }
            return false;
        },
        inline .big_integer, .big_decimal, .timestamp, .document => |_, g| {
            // TODO
            std.log.warn("Unimplemented shape allocated decider `{s}`", .{@tagName(g)});
            return false;
        },
        else => return false,
    }
}

pub fn shapeTester(part: test_symbols.Part, id: SmithyId, options: ShapeOptions, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    var symbols = try test_symbols.setup(arena_alloc, part);
    defer symbols.deinit();

    var buffer = std.ArrayList(u8).init(arena_alloc);
    defer buffer.deinit();

    var build = ContainerBuild.init(arena_alloc);
    writeShapeDecleration(arena_alloc, &symbols, &build, id, options) catch |err| {
        build.deinit();
        return err;
    };

    var codegen = Writer.init(arena_alloc, buffer.writer().any());
    defer codegen.deinit();

    const container = build.consume() catch |err| {
        build.deinit();
        return err;
    };

    codegen.appendValue(container) catch |err| {
        container.deinit(arena_alloc);
        return err;
    };

    try testing.expectEqualStrings(expected, buffer.items);
}

pub const TEST_INVOKER = blk: {
    var builder = jobz.InvokerBuilder{};

    _ = builder.Override(clnt.ClientOperationFuncHook, "Test Operation Func", struct {
        fn f(_: *const Delegate, bld: *BlockBuild, _: clnt.OperationFunc) anyerror!void {
            try bld.returns().raw("undefined").end();
        }
    }.f, .{});

    break :blk builder.consume();
};
