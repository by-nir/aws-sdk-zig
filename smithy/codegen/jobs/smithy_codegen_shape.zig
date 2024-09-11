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
const syb = @import("../systems/symbols.zig");
const SmithyId = syb.SmithyId;
const SmithyType = syb.SmithyType;
const SymbolsProvider = syb.SymbolsProvider;
const name_util = @import("../utils/names.zig");
const IssuesBag = @import("../utils/IssuesBag.zig");
const JsonValue = @import("../utils/JsonReader.zig").Value;
const cnfg = @import("../config.zig");
const ScopeTag = @import("smithy.zig").ScopeTag;
const CodegenPolicy = @import("smithy_codegen.zig").CodegenPolicy;
const trt_auth = @import("../traits/auth.zig");
const trt_docs = @import("../traits/docs.zig");
const trt_http = @import("../traits/http.zig");
const trt_refine = @import("../traits/refine.zig");
const trt_behave = @import("../traits/behavior.zig");
const trt_constr = @import("../traits/constraint.zig");
const test_symbols = @import("../testing/symbols.zig");

pub const ServiceAuthSchemesHook = Task.Hook("Smithy Service Auth Schemes", anyerror!void, &.{*std.ArrayList(SmithyId)});
pub const ServiceHeadHook = Task.Hook("Smithy Service Head", anyerror!void, &.{ *ContainerBuild, *const syb.SmithyService });
pub const ResourceHeadHook = Task.Hook("Smithy Resource Head", anyerror!void, &.{ *ContainerBuild, SmithyId, *const syb.SmithyResource });
pub const OperationShapeHook = Task.Hook("Smithy Operation Shape", anyerror!void, &.{ *BlockBuild, OperationShape });

pub const OperationShape = struct {
    id: SmithyId,
    input_type: ?[]const u8,
    output_type: ?[]const u8,
    errors_type: ?[]const u8,
    return_type: []const u8,
    auth_optional: bool,
    auth_priority: []const SmithyId,
};

pub const WriteShape = Task.Define("Smithy Write Shape", writeShapeTask, .{
    .injects = &.{ SymbolsProvider, IssuesBag },
});
fn writeShapeTask(
    self: *const Delegate,
    symbols: *SymbolsProvider,
    issues: *IssuesBag,
    bld: *ContainerBuild,
    id: SmithyId,
) !void {
    const shape = symbols.getShape(id) catch {
        const policy: CodegenPolicy = self.readValue(CodegenPolicy, ScopeTag.codegen_policy) orelse .{};
        switch (policy.unknown_shape) {
            .skip => return issues.add(.{ .codegen_unknown_shape = @intFromEnum(id) }),
            .abort => {
                std.log.err("Unknown shape: `{}`.", .{id});
                return IssuesBag.PolicyAbortError;
            },
        }
    };

    (switch (shape) {
        .list => |m| writeListShape(self, symbols, bld, id, m),
        .map => |m| writeMapShape(self, symbols, bld, id, m),
        .str_enum => |m| writeStrEnumShape(self, symbols, bld, id, m),
        .int_enum => |m| writeIntEnumShape(self, symbols, bld, id, m),
        .tagged_uinon => |m| writeUnionShape(self, symbols, bld, id, m),
        .structure => |m| writeStructShape(self, symbols, bld, id, m),
        .resource => |t| writeResourceShape(self, symbols, bld, id, t),
        .service => |t| writeServiceShape(self, symbols, bld, id, t),
        .string => if (trt_constr.Enum.get(symbols, id)) |members|
            writeTraitEnumShape(self, symbols, bld, id, members)
        else
            error.InvalidRootShape,
        else => error.InvalidRootShape,
    }) catch |e| {
        const shape_name = symbols.getShapeNameRaw(id);
        const name_id: IssuesBag.Issue.NameOrId = if (shape_name) |n|
            .{ .name = n }
        else |_|
            .{ .id = @intFromEnum(id) };

        const policy: CodegenPolicy = self.readValue(CodegenPolicy, ScopeTag.codegen_policy) orelse .{};
        switch (e) {
            error.InvalidRootShape => switch (policy.invalid_root) {
                .skip => {
                    try issues.add(.{ .codegen_invalid_root = name_id });
                    return;
                },
                .abort => {
                    if (shape_name) |n|
                        std.log.err("Invalid root shape: `{s}`.", .{n})
                    else |_|
                        std.log.err("Invalid root shape: `{}`.", .{id});
                    return IssuesBag.PolicyAbortError;
                },
            },
            else => switch (policy.shape_codegen_fail) {
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
                    return IssuesBag.PolicyAbortError;
                },
            },
        }
    };
}

test "WriteShape" {
    try smithyTester(&.{.unit}, struct {
        fn eval(tester: *jobz.PipelineTester, bld: *ContainerBuild) anyerror!void {
            try tester.runTask(WriteShape, .{ bld, SmithyId.of("test#Unit") });

            try testing.expectEqualDeep(&.{
                IssuesBag.Issue{ .codegen_invalid_root = .{ .id = @intFromEnum(SmithyId.of("test#Unit")) } },
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
) !void {
    const shape_name = try symbols.getShapeName(id, .type);
    const type_name = try symbols.getTypeName(memeber);
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

test "writeListShape" {
    try smithyTester(&.{.list}, struct {
        fn eval(tester: *jobz.PipelineTester, bld: *ContainerBuild) anyerror!void {
            try tester.runTask(WriteShape, .{ bld, SmithyId.of("test#List") });
            try tester.runTask(WriteShape, .{ bld, SmithyId.of("test#Set") });
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
) !void {
    const shape_name = try symbols.getShapeName(id, .type);
    const key_type = try symbols.getTypeName(memeber[0]);
    const val_type = try symbols.getTypeName(memeber[1]);
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

test "writeMapShape" {
    try smithyTester(&.{.map}, struct {
        fn eval(tester: *jobz.PipelineTester, bld: *ContainerBuild) anyerror!void {
            try tester.runTask(WriteShape, .{ bld, SmithyId.of("test#Map") });
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

test "writeEnumShape" {
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

    try smithyTester(&.{.enums_str}, struct {
        fn eval(tester: *jobz.PipelineTester, bld: *ContainerBuild) anyerror!void {
            try tester.runTask(WriteShape, .{ bld, SmithyId.of("test#Enum") });
            try tester.runTask(WriteShape, .{ bld, SmithyId.of("test#EnumTrt") });
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

test "writeIntEnumShape" {
    try smithyTester(&.{.enum_int}, struct {
        fn eval(tester: *jobz.PipelineTester, bld: *ContainerBuild) anyerror!void {
            try tester.runTask(WriteShape, .{ bld, SmithyId.of("test#IntEnum") });
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
) !void {
    const shape_name = try symbols.getShapeName(id, .type);
    try writeDocComment(self.alloc(), symbols, bld, id, false);

    const context = .{ .symbols = symbols, .members = members };
    try bld.public().constant(shape_name).assign(
        bld.x.@"union"().bodyWith(context, struct {
            fn f(ctx: @TypeOf(context), b: *ContainerBuild) !void {
                for (ctx.members) |m| {
                    const type_name = try ctx.symbols.getTypeName(m);
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

test "writeUnionShape" {
    try smithyTester(&.{.union_str}, struct {
        fn eval(tester: *jobz.PipelineTester, bld: *ContainerBuild) anyerror!void {
            try tester.runTask(WriteShape, .{ bld, SmithyId.of("test#Union") });
        }
    }.eval,
        \\pub const Union = union(enum) {
        \\    foo,
        \\    bar: i32,
        \\    baz: []const u8,
        \\};
    );
}

fn writeStructShape(
    self: *const Delegate,
    symbols: *SymbolsProvider,
    bld: *ContainerBuild,
    id: SmithyId,
    members: []const SmithyId,
) !void {
    const shape_name = try symbols.getShapeName(id, .type);
    try writeDocComment(self.alloc(), symbols, bld, id, false);

    const ShapeBodyCtx = struct {
        self: *const Delegate,
        symbols: *SymbolsProvider,
        id: SmithyId,
        members: []const SmithyId,
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

            try writeStructShapeMixin(ctx.self.alloc(), ctx.symbols, b, is_input, ctx.id);
            for (ctx.members) |m| {
                try writeStructShapeMember(ctx.self.alloc(), ctx.symbols, b, is_input, m);
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

    try bld.public().constant(shape_name).assign(
        bld.x.@"struct"().bodyWith(ShapeBodyCtx{
            .self = self,
            .symbols = symbols,
            .id = id,
            .members = members,
        }, Closures.shapeBody),
    );
}

fn writeStructShapeMixin(arena: Allocator, symbols: *SymbolsProvider, bld: *ContainerBuild, is_input: bool, id: SmithyId) !void {
    const mixins = symbols.getMixins(id) orelse return;
    for (mixins) |mix_id| {
        try writeStructShapeMixin(arena, symbols, bld, is_input, mix_id);
        const mixin = (try symbols.getShape(mix_id)).structure;
        for (mixin) |m| {
            try writeStructShapeMember(arena, symbols, bld, is_input, m);
        }
    }
}

fn writeStructShapeMember(arena: Allocator, symbols: *SymbolsProvider, bld: *ContainerBuild, is_input: bool, id: SmithyId) !void {
    const shape_name = try symbols.getShapeName(id, .field);
    const is_optional = isStructShapeMemberOptional(symbols, id, is_input);

    var type_expr = bld.x.raw(try symbols.getTypeName(id));
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

test "writeStructShape" {
    try smithyTester(&.{ .structure, .err }, struct {
        fn eval(tester: *jobz.PipelineTester, bld: *ContainerBuild) anyerror!void {
            try tester.runTask(WriteShape, .{ bld, SmithyId.of("test#Struct") });
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

fn writeOperationShapes(self: *const Delegate, symbols: *SymbolsProvider, bld: *ContainerBuild, id: SmithyId) !void {
    const operation = (try symbols.getShape(id)).operation;

    if (operation.input) |in_id| {
        const members = (try symbols.getShape(in_id)).structure;
        try writeStructShape(self, symbols, bld, in_id, members);
    }

    if (operation.output) |out_id| {
        const members = (try symbols.getShape(out_id)).structure;
        try writeStructShape(self, symbols, bld, out_id, members);
    }
}

test "writeOperationShapes" {
    const OpTest = Task.Define("Operation Test", struct {
        fn eval(self: *const Delegate, symbols: *SymbolsProvider, bld: *ContainerBuild) anyerror!void {
            try writeOperationShapes(self, symbols, bld, SmithyId.of("test.serve#Operation"));
        }
    }.eval, .{
        .injects = &.{SymbolsProvider},
    });

    try smithyTester(&.{.service}, struct {
        fn eval(tester: *jobz.PipelineTester, bld: *ContainerBuild) anyerror!void {
            try tester.runTask(OpTest, .{bld});
        }
    }.eval,
        \\pub const OperationInput = struct {
        \\    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        \\        try jw.beginObject();
        \\
        \\        try jw.endObject();
        \\    }
        \\};
        \\
        \\pub const OperationOutput = struct {
        \\    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        \\        try jw.beginObject();
        \\
        \\        try jw.endObject();
        \\    }
        \\};
    );
}

fn writeOperationFunc(self: *const Delegate, symbols: *SymbolsProvider, bld: *ContainerBuild, id: SmithyId) !void {
    const operation = (try symbols.getShape(id)).operation;
    const op_name = try symbols.getShapeName(id, .function);

    const service_errors = try symbols.getServiceErrors();
    const error_type = if (operation.errors.len + service_errors.len > 0)
        try errorSetName(self.alloc(), op_name, "srvc_errors.")
    else
        null;

    const input_type: ?[]const u8 = if (operation.input) |d| blk: {
        try symbols.markVisited(d);
        break :blk try symbols.getTypeName(d);
    } else null;
    const output_type: ?[]const u8 = if (operation.output) |d| blk: {
        try symbols.markVisited(d);
        break :blk try symbols.getTypeName(d);
    } else null;

    const return_type = if (error_type) |errors|
        try std.fmt.allocPrint(self.alloc(), "!smithy.Response({s}, {s})", .{
            output_type orelse "void",
            errors,
        })
    else if (output_type) |s|
        try std.fmt.allocPrint(self.alloc(), "!{s}", .{s})
    else
        "!void";

    const auth_optional = symbols.hasTrait(id, trt_auth.optional_auth_id);
    const auth_priority = trt_auth.Auth.get(symbols, id) orelse symbols.getServiceAuthPriority();

    const shape = OperationShape{
        .id = id,
        .input_type = input_type,
        .output_type = output_type,
        .errors_type = error_type,
        .return_type = return_type,
        .auth_optional = auth_optional,
        .auth_priority = auth_priority,
    };

    const context = .{ .self = self, .symbols = symbols, .shape = shape };
    const func1 = bld.public().function(op_name)
        .arg("self", bld.x.id(cnfg.service_client_type))
        .arg(cnfg.alloc_param, bld.x.raw("Allocator"));
    const func2 = if (input_type) |input| func1.arg("input", bld.x.raw(input)) else func1;
    try func2.returns(bld.x.raw(return_type)).bodyWith(context, struct {
        fn f(ctx: @TypeOf(context), b: *BlockBuild) !void {
            try ctx.self.evaluate(OperationShapeHook, .{ b, ctx.shape });
        }
    }.f);
}

test "writeOperationFunc" {
    const OpFuncTest = Task.Define("Operation Function Test", struct {
        fn eval(self: *const Delegate, symbols: *SymbolsProvider, bld: *ContainerBuild) anyerror!void {
            try writeOperationFunc(self, symbols, bld, SmithyId.of("test.serve#Operation"));
        }
    }.eval, .{
        .injects = &.{SymbolsProvider},
    });

    try smithyTester(&.{.service}, struct {
        fn eval(tester: *jobz.PipelineTester, bld: *ContainerBuild) anyerror!void {
            try tester.runTask(OpFuncTest, .{bld});
        }
    }.eval,
        \\pub fn operation(self: Client, allocator: Allocator, input: OperationInput) !smithy.Response(OperationOutput, srvc_errors.OperationError) {
        \\    return undefined;
        \\}
    );
}

fn writeResourceShape(
    self: *const Delegate,
    symbols: *SymbolsProvider,
    bld: *ContainerBuild,
    id: SmithyId,
    resource: *const syb.SmithyResource,
) !void {
    const LIFECYCLE_OPS = &.{ "create", "put", "read", "update", "delete", "list" };
    const resource_name = try symbols.getShapeName(id, .type);
    const context = .{ .self = self, .symbols = symbols, .id = id, .resource = resource };
    try bld.public().constant(resource_name).assign(bld.x.@"struct"().bodyWith(context, struct {
        fn f(ctx: @TypeOf(context), b: *ContainerBuild) !void {
            if (ctx.self.hasOverride(ResourceHeadHook)) {
                try ctx.self.evaluate(ResourceHeadHook, .{ b, ctx.id, ctx.resource });
            }
            for (ctx.resource.identifiers) |d| {
                try writeDocComment(ctx.self.alloc(), ctx.symbols, b, d.shape, true);
                const type_name = try ctx.symbols.getTypeName(d.shape);
                const shape_name = try name_util.snakeCase(ctx.self.alloc(), d.name);
                try b.field(shape_name).typing(b.x.raw(type_name)).end();
            }

            inline for (LIFECYCLE_OPS) |field| {
                if (@field(ctx.resource, field)) |op_id| {
                    try writeOperationFunc(ctx.self, ctx.symbols, b, op_id);
                }
            }
            for (ctx.resource.operations) |op_id| try writeOperationFunc(ctx.self, ctx.symbols, b, op_id);
            for (ctx.resource.collection_ops) |op_id| try writeOperationFunc(ctx.self, ctx.symbols, b, op_id);
        }
    }.f));

    inline for (LIFECYCLE_OPS) |field| {
        if (@field(resource, field)) |op_id| {
            try writeOperationShapes(self, symbols, bld, op_id);
        }
    }
    for (resource.operations) |op_id| try writeOperationShapes(self, symbols, bld, op_id);
    for (resource.collection_ops) |op_id| try writeOperationShapes(self, symbols, bld, op_id);

    for (resource.resources) |rsc_id| try symbols.enqueue(rsc_id);
}

test "writeResourceShape" {
    try smithyTester(&.{.service}, struct {
        fn eval(tester: *jobz.PipelineTester, bld: *ContainerBuild) anyerror!void {
            try tester.runTask(WriteShape, .{ bld, SmithyId.of("test.serve#Resource") });
        }
    }.eval,
        \\pub const Resource = struct {
        \\    forecast_id: []const u8,
        \\
        \\    pub fn operation(self: Client, allocator: Allocator, input: OperationInput) !smithy.Response(OperationOutput, srvc_errors.OperationError) {
        \\        return undefined;
        \\    }
        \\};
        \\
        \\pub const OperationInput = struct {
        \\    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        \\        try jw.beginObject();
        \\
        \\        try jw.endObject();
        \\    }
        \\};
        \\
        \\pub const OperationOutput = struct {
        \\    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        \\        try jw.beginObject();
        \\
        \\        try jw.endObject();
        \\    }
        \\};
    );
}

fn writeServiceShape(
    self: *const Delegate,
    symbols: *SymbolsProvider,
    bld: *ContainerBuild,
    id: SmithyId,
    service: *const syb.SmithyService,
) !void {
    //
    // Auth schemes
    //

    std.debug.assert(symbols.service_auth_schemes.len == 0);
    var auth_schemes = std.ArrayList(SmithyId).init(self.alloc());

    const auth_traits_ids: []const SmithyId = &.{
        trt_auth.http_basic_id,
        trt_auth.http_bearer_id,
        trt_auth.http_digest_id,
        trt_auth.HttpApiKey.id,
    };
    for (auth_traits_ids) |tid| {
        if (symbols.hasTrait(symbols.service_id, tid)) try auth_schemes.append(tid);
    }

    if (self.hasOverride(ServiceAuthSchemesHook)) {
        try self.evaluate(ServiceAuthSchemesHook, .{&auth_schemes});
    }

    symbols.service_auth_schemes = try auth_schemes.toOwnedSlice();
    errdefer symbols.service_auth_schemes = &.{};

    //
    // Client struct
    //

    try writeDocComment(self.alloc(), symbols, bld, id, false);
    const context = .{ .self = self, .symbols = symbols, .service = service };
    try bld.public().constant(cnfg.service_client_type).assign(
        bld.x.@"struct"().bodyWith(context, struct {
            fn f(ctx: @TypeOf(context), b: *ContainerBuild) !void {
                if (ctx.self.hasOverride(ServiceHeadHook)) {
                    try ctx.self.evaluate(ServiceHeadHook, .{ b, ctx.service });
                }

                for (ctx.service.operations) |op_id| {
                    try writeOperationFunc(ctx.self, ctx.symbols, b, op_id);
                }
            }
        }.f),
    );

    for (service.operations) |op_id| {
        try writeOperationShapes(self, symbols, bld, op_id);
    }
}

test "writeServiceShape" {
    try smithyTester(&.{.service_with_input_members}, struct {
        fn eval(tester: *jobz.PipelineTester, bld: *ContainerBuild) anyerror!void {
            try tester.runTask(WriteShape, .{ bld, SmithyId.of("test.serve#Service") });
        }
    }.eval,
        \\/// Some _service_...
        \\pub const Client = struct {
        \\    pub fn operation(self: Client, allocator: Allocator, input: OperationInput) !smithy.Response(OperationOutput, srvc_errors.OperationError) {
        \\        return undefined;
        \\    }
        \\};
        \\
        \\pub const OperationInput = struct {
        \\    foo: bool,
        \\    bar: ?bool = null,
        \\
        \\    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        \\        try jw.beginObject();
        \\
        \\        try jw.objectField("Foo");
        \\
        \\        try jw.write(self.foo);
        \\
        \\        if (self.bar) |v| {
        \\            try jw.objectField("Bar");
        \\
        \\            try jw.write(v);
        \\        }
        \\
        \\        try jw.endObject();
        \\    }
        \\};
        \\
        \\pub const OperationOutput = struct {
        \\    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        \\        try jw.beginObject();
        \\
        \\        try jw.endObject();
        \\    }
        \\};
    );
}

pub const WriteErrorSet = Task.Define("Smithy Write Error Set", writeErrorSetTask, .{
    .injects = &.{SymbolsProvider},
});
fn writeErrorSetTask(
    self: *const Delegate,
    symbols: *SymbolsProvider,
    bld: *ContainerBuild,
    shape_id: SmithyId,
    shape_errors: []const SmithyId,
    common_errors: []const SmithyId,
) anyerror!void {
    if (shape_errors.len + common_errors.len == 0) return;

    const shape_name = try symbols.getShapeName(shape_id, .type);
    const type_name = try errorSetName(self.alloc(), shape_name, "");

    const context = .{ .arena = self.alloc(), .symbols = symbols, .common_errors = common_errors, .shape_errors = shape_errors };
    try bld.public().constant(type_name).assign(bld.x.@"enum"().bodyWith(context, struct {
        fn f(ctx: @TypeOf(context), b: *ContainerBuild) !void {
            var members = std.ArrayList(ErrorSetMember).init(ctx.arena);
            defer members.deinit();

            for (ctx.common_errors) |m| try writeErrorSetMember(ctx.arena, ctx.symbols, b, &members, m);
            for (ctx.shape_errors) |m| try writeErrorSetMember(ctx.arena, ctx.symbols, b, &members, m);

            try b.public().function("source")
                .arg("self", b.x.This())
                .returns(b.x.raw("smithy.ErrorSource"))
                .bodyWith(members.items, writeErrorSetSourceFn);

            try b.public().function("httpStatus")
                .arg("self", b.x.This())
                .returns(b.x.raw("std.http.Status"))
                .bodyWith(members.items, writeErrorSetStatusFn);

            try b.public().function("retryable")
                .arg("self", b.x.This())
                .returns(b.x.typeOf(bool))
                .bodyWith(members.items, writeErrorSetRetryFn);
        }
    }.f));
}

const ErrorSetMember = struct {
    name: []const u8,
    code: u10,
    retryable: bool,
    source: trt_refine.Error.Source,
};

fn errorSetName(allocator: Allocator, shape_name: []const u8, comptime prefix: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, prefix ++ "{c}{s}Error", .{
        std.ascii.toUpper(shape_name[0]),
        shape_name[1..shape_name.len],
    });
}

fn writeErrorSetMember(
    arena: Allocator,
    symbols: *SymbolsProvider,
    bld: *ContainerBuild,
    list: *std.ArrayList(ErrorSetMember),
    member: SmithyId,
) !void {
    var shape_name = try symbols.getShapeName(member, .field);
    inline for (.{ "_error", "_exception" }) |suffix| {
        if (std.ascii.endsWithIgnoreCase(shape_name, suffix)) {
            shape_name = shape_name[0 .. shape_name.len - suffix.len];
            break;
        }
    }

    try writeDocComment(arena, symbols, bld, member, true);
    try bld.field(shape_name).end();

    const source = trt_refine.Error.get(symbols, member) orelse return error.MissingErrorTrait;
    try list.append(.{
        .name = shape_name,
        .source = source,
        .retryable = symbols.hasTrait(member, trt_behave.retryable_id),
        .code = trt_http.HttpError.get(symbols, member) orelse if (source == .client) 400 else 500,
    });
}

fn writeErrorSetSourceFn(members: []ErrorSetMember, bld: *BlockBuild) !void {
    try bld.returns().switchWith(bld.x.id("self"), members, struct {
        fn f(ms: []ErrorSetMember, b: *zig.SwitchBuild) !void {
            for (ms) |m| try b.branch().case(b.x.dot().id(m.name)).body(b.x.raw(switch (m.source) {
                .client => ".client",
                .server => ".server",
            }));
        }
    }.f).end();
}

fn writeErrorSetStatusFn(members: []ErrorSetMember, bld: *BlockBuild) !void {
    try bld.constant("code").assign(bld.x.switchWith(bld.x.id("self"), members, struct {
        fn f(ms: []ErrorSetMember, b: *zig.SwitchBuild) !void {
            for (ms) |m| try b.branch().case(b.x.dot().id(m.name)).body(b.x.valueOf(m.code));
        }
    }.f));

    try bld.returns().call("@enumFromInt", &.{bld.x.id("code")}).end();
}

fn writeErrorSetRetryFn(members: []ErrorSetMember, bld: *BlockBuild) !void {
    try bld.returns().switchWith(bld.x.id("self"), members, struct {
        fn f(ms: []ErrorSetMember, b: *zig.SwitchBuild) !void {
            for (ms) |m| try b.branch().case(b.x.dot().id(m.name)).body(b.x.valueOf(m.retryable));
        }
    }.f).end();
}

test "WriteErrorSet" {
    try smithyTester(&.{ .service, .err }, struct {
        fn eval(tester: *jobz.PipelineTester, bld: *ContainerBuild) anyerror!void {
            try tester.runTask(WriteErrorSet, .{
                bld,
                SmithyId.of("test.serve#Operation"),
                &.{SmithyId.of("test.error#NotFound")},
                &.{SmithyId.of("test#ServiceError")},
            });
        }
    }.eval, TEST_OPERATION_ERR);
}
pub const TEST_OPERATION_ERR =
    \\pub const OperationError = enum {
    \\    service,
    \\    not_found,
    \\
    \\    pub fn source(self: @This()) smithy.ErrorSource {
    \\        return switch (self) {
    \\            .service => .client,
    \\            .not_found => .server,
    \\        };
    \\    }
    \\
    \\    pub fn httpStatus(self: @This()) std.http.Status {
    \\        const code = switch (self) {
    \\            .service => 429,
    \\            .not_found => 500,
    \\        };
    \\
    \\        return @enumFromInt(code);
    \\    }
    \\
    \\    pub fn retryable(self: @This()) bool {
    \\        return switch (self) {
    \\            .service => true,
    \\            .not_found => false,
    \\        };
    \\    }
    \\};
;

fn writeDocComment(
    arena: Allocator,
    symbols: *SymbolsProvider,
    bld: *ContainerBuild,
    id: SmithyId,
    target_fallback: bool,
) !void {
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

test "writeDocument" {
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

fn smithyTester(
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

    try tester.defineValue(CodegenPolicy, ScopeTag.codegen_policy, .{
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

    _ = builder.Override(OperationShapeHook, "Test Operation Shape", struct {
        fn f(_: *const Delegate, bld: *BlockBuild, _: OperationShape) anyerror!void {
            try bld.returns().raw("undefined").end();
        }
    }.f, .{});

    break :blk builder.consume();
};
