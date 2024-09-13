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
const ScopeTag = @import("../pipeline.zig").ScopeTag;
const CodegenBehavior = @import("issues.zig").CodegenBehavior;
const mdl = @import("../model.zig");
const SmithyId = mdl.SmithyId;
const SmithyType = mdl.SmithyType;
const cfg = @import("../config.zig");
const isu = @import("../systems/issues.zig");
const IssuesBag = isu.IssuesBag;
const SymbolsProvider = @import("../systems/SymbolsProvider.zig");
const name_util = @import("../utils/names.zig");
const JsonValue = @import("../utils/JsonReader.zig").Value;
const trt_docs = @import("../traits/docs.zig");
const trt_refine = @import("../traits/refine.zig");
const trt_constr = @import("../traits/constraint.zig");
const test_symbols = @import("../testing/symbols.zig");

pub fn getShapeSafe(self: *const Delegate, symbols: *SymbolsProvider, issues: *IssuesBag, id: SmithyId) !?SmithyType {
    return symbols.getShape(id) catch {
        const behavior: CodegenBehavior = self.readValue(CodegenBehavior, ScopeTag.codegen_behavior) orelse .{};
        switch (behavior.unknown_shape) {
            .skip => {
                try issues.add(.{ .codegen_unknown_shape = @intFromEnum(id) });
                return null;
            },
            .abort => {
                std.log.err("Unknown shape: `{}`.", .{id});
                return isu.AbortError;
            },
        }
    };
}

pub fn handleShapeWriteError(self: *const Delegate, symbols: *SymbolsProvider, issues: *IssuesBag, id: SmithyId, e: anyerror) !void {
    const shape_name = symbols.getShapeNameRaw(id);
    const name_id: isu.Issue.NameOrId = if (shape_name) |n|
        .{ .name = n }
    else |_|
        .{ .id = @intFromEnum(id) };

    const behavior: CodegenBehavior = self.readValue(CodegenBehavior, ScopeTag.codegen_behavior) orelse .{};
    switch (e) {
        error.InvalidRootShape => switch (behavior.invalid_root) {
            .skip => {
                try issues.add(.{ .codegen_invalid_root = name_id });
                return;
            },
            .abort => {
                if (shape_name) |n|
                    std.log.err("Invalid root shape: `{s}`.", .{n})
                else |_|
                    std.log.err("Invalid root shape: `{}`.", .{id});
                return isu.AbortError;
            },
        },
        else => switch (behavior.shape_codegen_fail) {
            .skip => {
                return issues.add(.{ .codegen_shape_fail = .{
                    .err = e,
                    .item = name_id,
                } });
            },
            .abort => {
                if (shape_name) |n|
                    std.log.err("Shape `{s}` codegen failed: `{s}`.", .{ n, @errorName(e) })
                else |_|
                    std.log.err("Shape `{}` codegen failed: `{s}`.", .{ id, @errorName(e) });
                return isu.AbortError;
            },
        },
    }
}

pub const WriteShape = Task.Define("Smithy Write Shape", writeShapeTask, .{
    .injects = &.{ SymbolsProvider, IssuesBag },
});
fn writeShapeTask(
    self: *const Delegate,
    symbols: *SymbolsProvider,
    issues: *IssuesBag,
    bld: *ContainerBuild,
    id: SmithyId,
    named_scope: bool,
) !void {
    const shape = (try getShapeSafe(self, symbols, issues, id)) orelse return;
    _ = switch (shape) {
        .operation, .resource, .service => unreachable,
        .list => |m| writeListShape(self, symbols, bld, id, m, named_scope),
        .map => |m| writeMapShape(self, symbols, bld, id, m, named_scope),
        .str_enum => |m| writeStrEnumShape(self, symbols, bld, id, m),
        .int_enum => |m| writeIntEnumShape(self, symbols, bld, id, m),
        .tagged_uinon => |m| writeUnionShape(self, symbols, bld, id, m, named_scope),
        .structure => |m| writeStructShape(self, symbols, bld, id, m, named_scope, null),
        .string => if (trt_constr.Enum.get(symbols, id)) |members|
            writeTraitEnumShape(self, symbols, bld, id, members)
        else
            error.InvalidRootShape,
        else => error.InvalidRootShape,
    } catch |e| {
        return handleShapeWriteError(self, symbols, issues, id, e);
    };
}

test WriteShape {
    try shapeTester(&.{.unit}, struct {
        fn eval(tester: *jobz.PipelineTester, bld: *ContainerBuild) anyerror!void {
            try tester.runTask(WriteShape, .{ bld, SmithyId.of("test#Unit"), false });

            try testing.expectEqualDeep(&.{
                isu.Issue{ .codegen_invalid_root = .{ .id = @intFromEnum(SmithyId.of("test#Unit")) } },
            }, tester.getService(IssuesBag).?.all());
        }
    }.eval, "");
}

fn writeListShape(
    self: *const Delegate,
    symbols: *SymbolsProvider,
    bld: *ContainerBuild,
    id: SmithyId,
    memeber: SmithyId,
    named_scope: bool,
) !void {
    const shape_name = try symbols.getShapeName(id, .type);
    const type_name = try typeName(symbols, memeber, named_scope);
    try writeDocComment(self.alloc(), symbols, bld, id, false);

    const target_exp = if (symbols.hasTrait(id, trt_constr.unique_items_id)) blk: {
        break :blk bld.x.call("*const smithy.Set", &.{bld.x.raw(type_name)});
    } else if (symbols.hasTrait(id, trt_refine.sparse_id)) blk: {
        break :blk bld.x.typeSlice(false, bld.x.typeOptional(bld.x.raw(type_name)));
    } else blk: {
        break :blk bld.x.typeSlice(false, bld.x.raw(type_name));
    };

    try bld.public().constant(shape_name).assign(target_exp);
}

test writeListShape {
    try shapeTester(&.{.list}, struct {
        fn eval(tester: *jobz.PipelineTester, bld: *ContainerBuild) anyerror!void {
            try tester.runTask(WriteShape, .{ bld, SmithyId.of("test#List"), false });
            try tester.runTask(WriteShape, .{ bld, SmithyId.of("test#Set"), false });
        }
    }.eval,
        \\pub const List = []const ?i32;
        \\
        \\pub const Set = *const smithy.Set(i32);
    );
}

fn writeMapShape(
    self: *const Delegate,
    symbols: *SymbolsProvider,
    bld: *ContainerBuild,
    id: SmithyId,
    memeber: [2]SmithyId,
    named_scope: bool,
) !void {
    const shape_name = try symbols.getShapeName(id, .type);
    const key_type = try typeName(symbols, memeber[0], named_scope);
    const val_type = try typeName(symbols, memeber[1], named_scope);
    try writeDocComment(self.alloc(), symbols, bld, id, false);

    var value: ExprBuild = bld.x.raw(val_type);
    if (symbols.hasTrait(id, trt_refine.sparse_id))
        value = bld.x.typeOptional(value);

    var fn_name: []const u8 = undefined;
    var args: []const ExprBuild = undefined;
    if (std.mem.eql(u8, key_type, "[]const u8")) {
        fn_name = "*const std.StringArrayHashMapUnmanaged";
        args = &.{value};
    } else {
        fn_name = "*const std.AutoArrayHashMapUnmanaged";
        args = &.{ bld.x.raw(key_type), value };
    }

    try bld.public().constant(shape_name).assign(bld.x.call(fn_name, args));
}

test writeMapShape {
    try shapeTester(&.{.map}, struct {
        fn eval(tester: *jobz.PipelineTester, bld: *ContainerBuild) anyerror!void {
            try tester.runTask(WriteShape, .{ bld, SmithyId.of("test#Map"), false });
        }
    }.eval, "pub const Map = *const std.AutoArrayHashMapUnmanaged(i32, ?i32);");
}

fn writeStrEnumShape(
    self: *const Delegate,
    symbols: *SymbolsProvider,
    bld: *ContainerBuild,
    id: SmithyId,
    members: []const SmithyId,
) !void {
    var list = try EnumList.initCapacity(self.alloc(), members.len);
    defer list.deinit();
    for (members) |m| {
        const value = trt_refine.EnumValue.get(symbols, m);
        const value_str = if (value) |v| v.string else try symbols.getShapeName(m, .constant);
        const field_name = try symbols.getShapeName(m, .field);
        list.appendAssumeCapacity(.{
            .value = value_str,
            .field = field_name,
        });
    }
    try writeEnumShape(self.alloc(), symbols, bld, id, list.items);
}

fn writeTraitEnumShape(
    self: *const Delegate,
    symbols: *SymbolsProvider,
    bld: *ContainerBuild,
    id: SmithyId,
    members: []const trt_constr.Enum.Member,
) !void {
    var list = try EnumList.initCapacity(self.alloc(), members.len);
    defer list.deinit();
    for (members) |m| {
        list.appendAssumeCapacity(.{
            .value = m.value,
            .field = try name_util.snakeCase(self.alloc(), m.name orelse m.value),
        });
    }
    try writeEnumShape(self.alloc(), symbols, bld, id, list.items);
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
) !void {
    const context = .{ .arena = arena, .members = members };
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

            try b.constant("ParseMap").assign(b.x.raw("std.StaticStringMap(@This())"));
            try b.constant("parse_map").assign(
                b.x.call("ParseMap.initComptime", &.{
                    b.x.structLiteral(null, literals.items),
                }),
            );

            try b.public().function("parse")
                .arg("value", b.x.typeOf([]const u8))
                .returns(b.x.This())
                .body(parse);

            try b.public().function("jsonStringify")
                .arg("self", b.x.This())
                .arg("jw", null)
                .returns(b.x.raw("!void"))
                .bodyWith(ctx, serialize);
        }

        fn parse(b: *BlockBuild) !void {
            try b.returns().raw("parse_map.get(value) orelse .{ .UNKNOWN = value }").end();
        }

        fn serialize(ctx: @TypeOf(context), b: *BlockBuild) !void {
            try b.trys().call("jw.write", &.{b.x.switchWith(b.x.raw("self"), ctx, serializeSwitch)}).end();
        }

        fn serializeSwitch(ctx: @TypeOf(context), b: *zig.SwitchBuild) !void {
            try b.branch().case(b.x.valueOf(.UNKNOWN)).capture("s").body(b.x.raw("s"));
            for (ctx.members) |m| {
                try b.branch().case(b.x.dot().raw(m.field)).body(b.x.valueOf(m.value));
            }
        }
    };

    const shape_name = try symbols.getShapeName(id, .type);
    try writeDocComment(arena, symbols, bld, id, false);
    try bld.public().constant(shape_name).assign(
        bld.x.@"union"().bodyWith(context, Closures.shape),
    );
}

test writeEnumShape {
    const BODY =
        \\    /// Used for backwards compatibility when adding new values.
        \\    UNKNOWN: []const u8,
        \\    foo_bar,
        \\    baz_qux,
        \\
        \\    const ParseMap = std.StaticStringMap(@This());
        \\
        \\    const parse_map = ParseMap.initComptime(.{ .{ "FOO_BAR", .foo_bar }, .{ "baz$qux", .baz_qux } });
        \\
        \\    pub fn parse(value: []const u8) @This() {
        \\        return parse_map.get(value) orelse .{ .UNKNOWN = value };
        \\    }
        \\
        \\    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        \\        try jw.write(switch (self) {
        \\            .UNKNOWN => |s| s,
        \\            .foo_bar => "FOO_BAR",
        \\            .baz_qux => "baz$qux",
        \\        });
        \\    }
        \\};
    ;

    try shapeTester(&.{.enums_str}, struct {
        fn eval(tester: *jobz.PipelineTester, bld: *ContainerBuild) anyerror!void {
            try tester.runTask(WriteShape, .{ bld, SmithyId.of("test#Enum"), false });
            try tester.runTask(WriteShape, .{ bld, SmithyId.of("test#EnumTrt"), false });
        }
    }.eval, "pub const Enum = union(enum) {\n" ++ BODY ++ "\n\n" ++
        "pub const EnumTrt = union(enum) {\n" ++ BODY);
}

fn writeIntEnumShape(
    self: *const Delegate,
    symbols: *SymbolsProvider,
    bld: *ContainerBuild,
    id: SmithyId,
    members: []const SmithyId,
) !void {
    const context = .{ .symbols = symbols, .members = members };
    const Closures = struct {
        fn shape(ctx: @TypeOf(context), b: *ContainerBuild) !void {
            for (ctx.members) |m| {
                const shape_name = try ctx.symbols.getShapeName(m, .field);
                const shape_value = trt_refine.EnumValue.get(ctx.symbols, m).?.integer;
                try b.field(shape_name).assign(b.x.valueOf(shape_value));
            }
            try b.comment(.doc, "Used for backwards compatibility when adding new values.");
            try b.field("_").end();

            try b.public().function("parse")
                .arg("value", b.x.typeOf(i32))
                .returns(b.x.This())
                .body(parse);

            try b.public().function("jsonStringify")
                .arg("self", b.x.This())
                .arg("jw", null)
                .returns(b.x.raw("!void"))
                .body(serialize);
        }

        fn parse(b: *BlockBuild) !void {
            try b.returns().raw("@enumFromInt(value)").end();
        }

        fn serialize(b: *BlockBuild) !void {
            try b.constant("value").typing(b.x.typeOf(i32)).assign(b.x.raw("@intFromEnum(self)"));
            try b.trys().call("jw.write", &.{b.x.id("value")}).end();
        }
    };

    const shape_name = try symbols.getShapeName(id, .type);
    try writeDocComment(self.alloc(), symbols, bld, id, false);
    try bld.public().constant(shape_name).assign(
        bld.x.@"enum"().backedBy(bld.x.typeOf(i32)).bodyWith(context, Closures.shape),
    );
}

test writeIntEnumShape {
    try shapeTester(&.{.enum_int}, struct {
        fn eval(tester: *jobz.PipelineTester, bld: *ContainerBuild) anyerror!void {
            try tester.runTask(WriteShape, .{ bld, SmithyId.of("test#IntEnum"), false });
        }
    }.eval,
        \\/// An **integer-based** enumeration.
        \\pub const IntEnum = enum(i32) {
        \\    foo_bar = 8,
        \\    baz_qux = 9,
        \\    /// Used for backwards compatibility when adding new values.
        \\    _,
        \\
        \\    pub fn parse(value: i32) @This() {
        \\        return @enumFromInt(value);
        \\    }
        \\
        \\    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        \\        const value: i32 = @intFromEnum(self);
        \\
        \\        try jw.write(value);
        \\    }
        \\};
    );
}

fn writeUnionShape(
    self: *const Delegate,
    symbols: *SymbolsProvider,
    bld: *ContainerBuild,
    id: SmithyId,
    members: []const SmithyId,
    named_scope: bool,
) !void {
    const shape_name = try symbols.getShapeName(id, .type);
    try writeDocComment(self.alloc(), symbols, bld, id, false);

    const context = .{ .symbols = symbols, .members = members, .named = named_scope };
    try bld.public().constant(shape_name).assign(
        bld.x.@"union"().bodyWith(context, struct {
            fn f(ctx: @TypeOf(context), b: *ContainerBuild) !void {
                for (ctx.members) |m| {
                    const type_name = try typeName(ctx.symbols, m, ctx.named);
                    const member_name = try ctx.symbols.getShapeName(m, .field);
                    if (type_name.len > 0) {
                        try b.field(member_name).typing(b.x.raw(type_name)).end();
                    } else {
                        try b.field(member_name).end();
                    }
                }
            }
        }.f),
    );
}

test writeUnionShape {
    try shapeTester(&.{.union_str}, struct {
        fn eval(tester: *jobz.PipelineTester, bld: *ContainerBuild) anyerror!void {
            try tester.runTask(WriteShape, .{ bld, SmithyId.of("test#Union"), false });
        }
    }.eval,
        \\pub const Union = union(enum) {
        \\    foo,
        \\    bar: i32,
        \\    baz: []const u8,
        \\};
    );
}

pub fn writeStructShape(
    self: *const Delegate,
    symbols: *SymbolsProvider,
    bld: *ContainerBuild,
    id: SmithyId,
    members: []const SmithyId,
    named_scope: bool,
    override_name: ?[]const u8,
) !void {
    const ShapeBodyCtx = struct {
        self: *const Delegate,
        symbols: *SymbolsProvider,
        id: SmithyId,
        members: []const SmithyId,
        named_scope: bool,
    };

    const JsonStringifyFuncCtx = struct {
        symbols: *SymbolsProvider,
        members: []const SmithyId,
        is_input_struct: bool,
    };

    const JsonStringifyMemberCtx = struct {
        name: ExprBuild,
        type: SmithyType,
        value: ExprBuild,
    };

    const Closures = struct {
        fn shapeBody(ctx: ShapeBodyCtx, b: *ContainerBuild) !void {
            const is_input = ctx.symbols.hasTrait(ctx.id, trt_refine.input_id);

            try writeStructShapeMixin(ctx.self.alloc(), ctx.symbols, b, is_input, ctx.id, ctx.named_scope);
            for (ctx.members) |m| {
                try writeStructShapeMember(ctx.self.alloc(), ctx.symbols, b, is_input, m, ctx.named_scope);
            }

            const json_ctx: JsonStringifyFuncCtx = .{
                .symbols = ctx.symbols,
                .members = ctx.members,
                .is_input_struct = is_input,
            };

            try b.public().function("jsonStringify")
                .arg("self", b.x.This())
                .arg("jw", null)
                .returns(b.x.raw("!void"))
                .bodyWith(json_ctx, jsonStringifyFunc);
        }

        fn jsonStringifyFunc(ctx: JsonStringifyFuncCtx, b: *BlockBuild) !void {
            try b.raw("try jw.beginObject()");

            for (ctx.members) |mid| {
                const member_name = try ctx.symbols.getShapeNameRaw(mid);
                const field_name = try ctx.symbols.getShapeName(mid, .field);
                const field_expr = b.x.id("self").dot().id(field_name);
                const member_type = try ctx.symbols.getShapeUnwrap(mid);

                const is_optional = isStructShapeMemberOptional(ctx.symbols, mid, ctx.is_input_struct);
                const context: JsonStringifyMemberCtx = .{
                    .name = b.x.valueOf(member_name),
                    .type = member_type,
                    .value = if (is_optional) b.x.id("v") else field_expr,
                };
                if (is_optional)
                    try b.@"if"(field_expr).capture("v")
                        .body(b.x.blockWith(context, jsonStringifyMember)).end()
                else
                    try jsonStringifyMember(context, b);
            }

            try b.raw("try jw.endObject()");
        }

        fn jsonStringifyMember(ctx: JsonStringifyMemberCtx, b: *BlockBuild) anyerror!void {
            try b.trys().call("jw.objectField", &.{ctx.name}).end();

            switch (ctx.type) {
                .boolean, .structure, .string, .byte, .short, .integer, .long, .float, .double, .str_enum, .int_enum, .list, .timestamp => {
                    try b.trys().call("jw.write", &.{ctx.value}).end();
                },
                else => |t| std.debug.panic("Unsupported JSON stringify for type `{}`.", .{t}),
            }
        }
    };

    const shape_name = override_name orelse try symbols.getShapeName(id, .type);

    try writeDocComment(self.alloc(), symbols, bld, id, false);
    try bld.public().constant(shape_name).assign(
        bld.x.@"struct"().bodyWith(ShapeBodyCtx{
            .self = self,
            .symbols = symbols,
            .id = id,
            .members = members,
            .named_scope = named_scope,
        }, Closures.shapeBody),
    );
}

fn writeStructShapeMixin(
    arena: Allocator,
    symbols: *SymbolsProvider,
    bld: *ContainerBuild,
    is_input: bool,
    id: SmithyId,
    named_scope: bool,
) !void {
    const mixins = symbols.getMixins(id) orelse return;
    for (mixins) |mix_id| {
        try writeStructShapeMixin(arena, symbols, bld, is_input, mix_id, named_scope);
        const mixin = (try symbols.getShape(mix_id)).structure;
        for (mixin) |m| {
            try writeStructShapeMember(arena, symbols, bld, is_input, m, named_scope);
        }
    }
}

fn writeStructShapeMember(
    arena: Allocator,
    symbols: *SymbolsProvider,
    bld: *ContainerBuild,
    is_input: bool,
    id: SmithyId,
    named_scope: bool,
) !void {
    const shape_name = try symbols.getShapeName(id, .field);
    const is_optional = isStructShapeMemberOptional(symbols, id, is_input);

    var type_expr = bld.x.raw(try typeName(symbols, id, named_scope));
    if (is_optional) type_expr = bld.x.typeOptional(type_expr);

    try writeDocComment(arena, symbols, bld, id, true);
    const field = bld.field(shape_name).typing(type_expr);
    const assign: ?ExprBuild = blk: {
        if (is_optional) break :blk bld.x.valueOf(null);
        if (trt_refine.Default.get(symbols, id)) |json| {
            break :blk switch (try symbols.getShapeUnwrap(id)) {
                .str_enum => bld.x.dot().raw(json.string),
                .int_enum => bld.x.call("@enumFromInt", &.{bld.x.valueOf(json.integer)}),
                else => unreachable,
            };
        }
        break :blk null;
    };
    if (assign) |a| try field.assign(a) else try field.end();
}

/// https://smithy.io/2.0/spec/aggregate-types.html#structure-member-optionality
fn isStructShapeMemberOptional(symbols: *SymbolsProvider, id: SmithyId, is_input: bool) bool {
    if (is_input) return true;

    if (symbols.getTraits(id)) |bag| {
        return bag.has(trt_refine.client_optional_id) or
            !(bag.has(trt_refine.required_id) or bag.has(trt_refine.Default.id));
    }

    return true;
}

test writeStructShape {
    try shapeTester(&.{ .structure, .err }, struct {
        fn eval(tester: *jobz.PipelineTester, bld: *ContainerBuild) anyerror!void {
            try tester.runTask(WriteShape, .{ bld, SmithyId.of("test#Struct"), false });
        }
    }.eval,
        \\pub const Struct = struct {
        \\    mixed: ?bool = null,
        \\    /// A **struct** member.
        \\    foo_bar: i32,
        \\    /// An **integer-based** enumeration.
        \\    baz_qux: IntEnum = @enumFromInt(8),
        \\
        \\    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        \\        try jw.beginObject();
        \\
        \\        try jw.objectField("fooBar");
        \\
        \\        try jw.write(self.foo_bar);
        \\
        \\        try jw.objectField("bazQux");
        \\
        \\        try jw.write(self.baz_qux);
        \\
        \\        try jw.endObject();
        \\    }
        \\};
    );
}

pub fn writeDocComment(arena: Allocator, symbols: *SymbolsProvider, bld: *ContainerBuild, id: SmithyId, target_fallback: bool) !void {
    const docs = trt_docs.Documentation.get(symbols, id) orelse blk: {
        if (!target_fallback) break :blk null;
        const shape = symbols.getShape(id) catch break :blk null;
        break :blk switch (shape) {
            .target => |t| trt_docs.Documentation.get(symbols, t),
            else => null,
        };
    } orelse return;

    try bld.commentMarkdownWith(.doc, md.html.CallbackContext{
        .allocator = arena,
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

pub fn typeName(symbols: *SymbolsProvider, id: SmithyId, named_scope: bool) ![]const u8 {
    switch (id) {
        .str_enum, .int_enum, .list, .map, .structure, .tagged_uinon, .operation, .resource, .service, .apply => unreachable,
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
                inline .unit, .blob, .boolean, .string, .byte, .short, .integer, .long, .float, .double, .big_integer, .big_decimal, .timestamp, .document => |_, g| {
                    const type_id = std.enums.nameCast(SmithyId, g);
                    return try typeName(symbols, type_id, named_scope);
                },
                .target => |target| return try typeName(symbols, target, named_scope),
                else => {
                    const type_name = try symbols.getShapeName(shape_id, .type);
                    return switch (named_scope) {
                        false => type_name,
                        true => std.fmt.allocPrint(symbols.arena, cfg.types_scope ++ ".{s}", .{type_name}),
                    };
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
        var shapes: std.AutoHashMapUnmanaged(SmithyId, SmithyType) = .{};
        errdefer shapes.deinit(arena_alloc);
        try shapes.put(arena_alloc, foo_id, .{ .structure = &.{} });

        var names: std.AutoHashMapUnmanaged(SmithyId, []const u8) = .{};
        errdefer names.deinit(arena_alloc);
        try names.put(arena_alloc, foo_id, "Foo");

        break :blk .{
            .arena = arena_alloc,
            .service_id = SmithyId.NULL,
            .model_shapes = shapes,
            .model_names = names,
        };
    };
    defer symbols.deinit();

    try testing.expectError(error.UnexpectedDocumentShape, typeName(&symbols, SmithyId.document, false));

    try testing.expectEqualStrings("", try typeName(&symbols, .unit, false));
    try testing.expectEqualStrings("bool", try typeName(&symbols, .boolean, false));
    try testing.expectEqualStrings("i8", try typeName(&symbols, .byte, false));
    try testing.expectEqualStrings("i16", try typeName(&symbols, .short, false));
    try testing.expectEqualStrings("i32", try typeName(&symbols, .integer, false));
    try testing.expectEqualStrings("i64", try typeName(&symbols, .long, false));
    try testing.expectEqualStrings("f32", try typeName(&symbols, .float, false));
    try testing.expectEqualStrings("f64", try typeName(&symbols, .double, false));
    try testing.expectEqualStrings("u64", try typeName(&symbols, .timestamp, false));
    try testing.expectEqualStrings("[]const u8", try typeName(&symbols, .blob, false));
    try testing.expectEqualStrings("[]const u8", try typeName(&symbols, .string, false));
    try testing.expectEqualStrings("[]const u8", try typeName(&symbols, .big_integer, false));
    try testing.expectEqualStrings("[]const u8", try typeName(&symbols, .big_decimal, false));

    try testing.expectEqualStrings("Foo", try typeName(&symbols, foo_id, false));
    try testing.expectEqualStrings("srvc_types.Foo", try typeName(&symbols, foo_id, true));
}

pub fn shapeTester(
    setup_symbols: []const test_symbols.Case,
    eval: *const fn (tester: *jobz.PipelineTester, bld: *ContainerBuild) anyerror!void,
    expected: []const u8,
) !void {
    var tester = try jobz.PipelineTester.init(.{ .invoker = TEST_INVOKER });
    defer tester.deinit();

    _ = try tester.provideService(IssuesBag.init(test_alloc), struct {
        fn f(issues: *IssuesBag, _: Allocator) void {
            issues.deinit();
        }
    }.f);

    _ = try tester.provideService(try test_symbols.setup(tester.alloc(), setup_symbols), null);

    try tester.defineValue(CodegenBehavior, ScopeTag.codegen_behavior, .{
        .unknown_shape = .skip,
        .invalid_root = .skip,
        .shape_codegen_fail = .skip,
    });

    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var build = zig.ContainerBuild.init(tester.alloc());
    eval(&tester, &build) catch |err| {
        build.deinit();
        return err;
    };

    var codegen = Writer.init(test_alloc, buffer.writer().any());
    defer codegen.deinit();

    const container = build.consume() catch |err| {
        build.deinit();
        return err;
    };

    codegen.appendValue(container) catch |err| {
        container.deinit(test_alloc);
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
