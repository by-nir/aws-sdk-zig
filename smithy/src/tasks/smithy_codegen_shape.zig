const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const pipez = @import("../pipeline/root.zig");
const Task = pipez.Task;
const Delegate = pipez.Delegate;
const syb = @import("../systems/symbols.zig");
const SmithyId = syb.SmithyId;
const SmithyType = syb.SmithyType;
const SymbolsProvider = syb.SymbolsProvider;
const md = @import("../codegen/md.zig");
const zig = @import("../codegen/zig.zig");
const ExprBuild = zig.ExprBuild;
const BlockBuild = zig.BlockBuild;
const ContainerBuild = zig.ContainerBuild;
const Writer = @import("../codegen/CodegenWriter.zig");
const name_util = @import("../utils/names.zig");
const IssuesBag = @import("../utils/IssuesBag.zig");
const ScopeTag = @import("smithy.zig").ScopeTag;
const CodegenPolicy = @import("smithy_codegen.zig").CodegenPolicy;
const trt_docs = @import("../traits/docs.zig");
const trt_http = @import("../traits/http.zig");
const trt_refine = @import("../traits/refine.zig");
const trt_behave = @import("../traits/behavior.zig");
const trt_constr = @import("../traits/constraint.zig");
const test_symbols = @import("../testing/symbols.zig");

pub const ServiceHeadHook = Task.Hook("Smithy Service Head", anyerror!void, &.{ *ContainerBuild, *const syb.SmithyService });
pub const ResourceHeadHook = Task.Hook("Smithy Resource Head", anyerror!void, &.{ *ContainerBuild, SmithyId, *const syb.SmithyResource });
pub const ErrorShapeHook = Task.Hook("Smithy Error Shape", anyerror!void, &.{ *ContainerBuild, ErrorShape });
pub const OperationTypeHook = Task.Hook("Smithy Operation Type", anyerror!?[]const u8, &.{OperationShape});
pub const OperationShapeHook = Task.Hook("Smithy Operation Shape", anyerror!void, &.{ *BlockBuild, OperationShape });
pub const UniqueListTypeHook = Task.Hook("Smithy Unique List Type", anyerror![]const u8, &.{[]const u8});

pub const ErrorShape = struct {
    id: SmithyId,
    source: trt_refine.Error.Source,
    code: u10,
    retryable: bool,
};

pub const OperationShape = struct {
    id: SmithyId,
    input: ?Input,
    output_type: ?[]const u8,
    errors_type: ?[]const u8,

    pub const Input = struct {
        identifier: []const u8,
        type: []const u8,
    };
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
    const policy: CodegenPolicy = self.readValue(CodegenPolicy, ScopeTag.codegen_policy) orelse .{};

    const shape = symbols.getShape(id) catch switch (policy.unknown_shape) {
        .skip => return issues.add(.{ .codegen_unknown_shape = @intFromEnum(id) }),
        .abort => {
            std.log.err("Unknown shape: `{}`.", .{id});
            return IssuesBag.PolicyAbortError;
        },
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
        const shape_name = symbols.getShapeName(id, .type);
        const name_id: IssuesBag.Issue.NameOrId = if (shape_name) |n|
            .{ .name = n }
        else |_|
            .{ .id = @intFromEnum(id) };
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
        fn eval(tester: *pipez.PipelineTester, bld: *ContainerBuild) anyerror!void {
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
        if (self.hasOverride(UniqueListTypeHook)) {
            const unique_name = try self.evaluate(UniqueListTypeHook, .{type_name});
            break :blk bld.x.raw(unique_name);
        } else {
            break :blk bld.x.call(
                "*const std.AutoArrayHashMapUnmanaged",
                &.{ bld.x.raw(type_name), bld.x.raw("void") },
            );
        }
    } else if (symbols.hasTrait(id, trt_refine.sparse_id)) blk: {
        break :blk bld.x.typeSlice(false, bld.x.typeOptional(bld.x.raw(type_name)));
    } else blk: {
        break :blk bld.x.typeSlice(false, bld.x.raw(type_name));
    };

    try bld.public().constant(shape_name).assign(target_exp);
}

test "writeListShape" {
    try smithyTester(&.{.list}, struct {
        fn eval(tester: *pipez.PipelineTester, bld: *ContainerBuild) anyerror!void {
            try tester.runTask(WriteShape, .{ bld, SmithyId.of("test#List") });
            try tester.runTask(WriteShape, .{ bld, SmithyId.of("test#Set") });
        }
    }.eval,
        \\pub const List = []const ?i32;
        \\
        \\pub const Set = *const std.AutoArrayHashMapUnmanaged(i32, void);
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
        fn eval(tester: *pipez.PipelineTester, bld: *ContainerBuild) anyerror!void {
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

            try b.public().function("parse").arg("value", b.x.typeOf([]const u8))
                .returns(b.x.This()).body(parse);

            try b.public().function("serialize").arg("self", b.x.This())
                .returns(b.x.typeOf([]const u8)).bodyWith(ctx, serialize);
        }

        fn parse(b: *BlockBuild) !void {
            try b.returns().raw("parse_map.get(value) orelse .{ .UNKNOWN = value }").end();
        }

        fn serialize(ctx: @TypeOf(context), b: *BlockBuild) !void {
            try b.returns().switchWith(b.x.raw("self"), ctx, serializeSwitch).end();
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
        \\    pub fn serialize(self: @This()) []const u8 {
        \\        return switch (self) {
        \\            .UNKNOWN => |s| s,
        \\            .foo_bar => "FOO_BAR",
        \\            .baz_qux => "baz$qux",
        \\        };
        \\    }
        \\};
    ;

    try smithyTester(&.{.enums_str}, struct {
        fn eval(tester: *pipez.PipelineTester, bld: *ContainerBuild) anyerror!void {
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

            try b.public().function("parse").arg("value", b.x.typeOf(i32))
                .returns(b.x.This()).body(parse);

            try b.public().function("serialize").arg("self", b.x.This())
                .returns(b.x.typeOf(i32)).body(serialize);
        }

        fn parse(b: *BlockBuild) !void {
            try b.returns().raw("@enumFromInt(value)").end();
        }

        fn serialize(b: *BlockBuild) !void {
            try b.returns().raw("@intFromEnum(self)").end();
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
        fn eval(tester: *pipez.PipelineTester, bld: *ContainerBuild) anyerror!void {
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
        \\    pub fn serialize(self: @This()) i32 {
        \\        return @intFromEnum(self);
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
        fn eval(tester: *pipez.PipelineTester, bld: *ContainerBuild) anyerror!void {
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

    const context = .{ .self = self, .symbols = symbols, .id = id, .members = members };
    try bld.public().constant(shape_name).assign(
        bld.x.@"struct"().bodyWith(context, struct {
            fn f(ctx: @TypeOf(context), b: *ContainerBuild) !void {
                const is_input = ctx.symbols.hasTrait(ctx.id, trt_refine.input_id);
                try writeStructShapeError(ctx.self, ctx.symbols, b, ctx.id);
                try writeStructShapeMixin(ctx.self.alloc(), ctx.symbols, b, is_input, ctx.id);
                for (ctx.members) |m| {
                    try writeStructShapeMember(ctx.self.alloc(), ctx.symbols, b, is_input, m);
                }
            }
        }.f),
    );
}

fn writeStructShapeError(
    self: *const Delegate,
    symbols: *SymbolsProvider,
    bld: *ContainerBuild,
    id: SmithyId,
) !void {
    const source = trt_refine.Error.get(symbols, id) orelse return;
    try self.evaluate(ErrorShapeHook, .{ bld, .{
        .id = id,
        .source = source,
        .retryable = symbols.hasTrait(id, trt_behave.retryable_id),
        .code = trt_http.HttpError.get(symbols, id) orelse if (source == .client) 400 else 500,
    } });
}

fn writeStructShapeMixin(
    arena: Allocator,
    symbols: *SymbolsProvider,
    bld: *ContainerBuild,
    is_input: bool,
    id: SmithyId,
) !void {
    const mixins = symbols.getMixins(id) orelse return;
    for (mixins) |mix_id| {
        try writeStructShapeMixin(arena, symbols, bld, is_input, mix_id);
        const mixin = (try symbols.getShape(mix_id)).structure;
        for (mixin) |m| {
            try writeStructShapeMember(arena, symbols, bld, is_input, m);
        }
    }
}

fn writeStructShapeMember(
    arena: Allocator,
    symbols: *SymbolsProvider,
    bld: *ContainerBuild,
    is_input: bool,
    id: SmithyId,
) !void {
    // https://smithy.io/2.0/spec/aggregate-types.html#structure-member-optionality
    const optional: bool = if (is_input) true else if (symbols.getTraits(id)) |bag| blk: {
        break :blk bag.has(trt_refine.client_optional_id) or
            !(bag.has(trt_refine.required_id) or bag.has(trt_refine.Default.id));
    } else true;

    const shape_name = try symbols.getShapeName(id, .field);
    var type_expr = bld.x.raw(try symbols.getTypeName(id));
    if (optional) type_expr = bld.x.typeOptional(type_expr);

    try writeDocComment(arena, symbols, bld, id, true);
    const field = bld.field(shape_name).typing(type_expr);
    const assign: ?ExprBuild = blk: {
        if (optional) break :blk bld.x.valueOf(null);
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

test "writeStructShape" {
    try smithyTester(&.{ .structure, .err }, struct {
        fn eval(tester: *pipez.PipelineTester, bld: *ContainerBuild) anyerror!void {
            try tester.runTask(WriteShape, .{ bld, SmithyId.of("test#Struct") });
            try tester.runTask(WriteShape, .{ bld, SmithyId.of("test#Error") });
        }
    }.eval,
        \\pub const Struct = struct {
        \\    mixed: ?bool = null,
        \\    /// A **struct** member.
        \\    foo_bar: i32,
        \\    /// An **integer-based** enumeration.
        \\    baz_qux: IntEnum = @enumFromInt(8),
        \\};
        \\
        \\pub const Error = struct {
        \\    pub const source: ErrorSource = .client;
        \\
        \\    pub const code: u10 = 429;
        \\
        \\    pub const retryable = true;
        \\};
    );
}

fn writeOperationShapes(
    self: *const Delegate,
    symbols: *SymbolsProvider,
    bld: *ContainerBuild,
    id: SmithyId,
) !void {
    const operation = (try symbols.getShape(id)).operation;

    if (operation.input) |in_id| {
        const members = (try symbols.getShape(in_id)).structure;
        try writeStructShape(self, symbols, bld, in_id, members);
    }

    if (operation.output) |out_id| {
        const members = (try symbols.getShape(out_id)).structure;
        try writeStructShape(self, symbols, bld, out_id, members);
    }

    // We don't write directly since an error may be used by multiple operations.
    for (operation.errors) |err_id| try symbols.enqueue(err_id);
}

test "writeOperationShapes" {
    const OpTest = Task.Define("Operation Test", struct {
        fn eval(self: *const Delegate, symbols: *SymbolsProvider, bld: *ContainerBuild) anyerror!void {
            try writeOperationShapes(self, symbols, bld, SmithyId.of("test.serve#Operation"));
            try testing.expectEqual(SmithyId.of("test.error#NotFound"), symbols.next());
        }
    }.eval, .{
        .injects = &.{SymbolsProvider},
    });

    try smithyTester(&.{.service}, struct {
        fn eval(tester: *pipez.PipelineTester, bld: *ContainerBuild) anyerror!void {
            try tester.runTask(OpTest, .{bld});
        }
    }.eval,
        \\pub const OperationInput = struct {};
        \\
        \\pub const OperationOutput = struct {};
    );
}

fn writeOperationFunc(
    self: *const Delegate,
    symbols: *SymbolsProvider,
    bld: *ContainerBuild,
    id: SmithyId,
) !void {
    const service_errors = try symbols.getServiceErrors();
    const operation = (try symbols.getShape(id)).operation;
    const op_name = try symbols.getShapeName(id, .function);

    const errors_type = if (operation.errors.len + service_errors.len > 0)
        try writeOperationFuncError(self.alloc(), symbols, bld, op_name, operation.errors, service_errors)
    else
        null;

    const shape_input: ?OperationShape.Input = if (operation.input) |d| blk: {
        try symbols.markVisited(d);
        break :blk .{
            .identifier = "input",
            .type = try symbols.getTypeName(d),
        };
    } else null;

    const shape_output: ?[]const u8 = if (operation.output) |d| blk: {
        try symbols.markVisited(d);
        break :blk try symbols.getTypeName(d);
    } else null;

    const shape = OperationShape{
        .id = id,
        .input = shape_input,
        .output_type = shape_output,
        .errors_type = errors_type,
    };

    const return_type = if (self.hasOverride(OperationTypeHook)) blk: {
        const result = try self.evaluate(OperationTypeHook, .{shape});
        break :blk if (result) |s| bld.x.raw(s) else bld.x.typeOf(void);
    } else if (shape_output) |s| blk: {
        break :blk bld.x.raw(s);
    } else blk: {
        break :blk bld.x.typeOf(void);
    };

    const context = .{ .self = self, .symbols = symbols, .shape = shape };
    const func1 = bld.public().function(op_name).arg("self", bld.x.This());
    const func2 = if (shape_input) |input| func1.arg(input.identifier, bld.x.raw(input.type)) else func1;
    try func2.returns(return_type).bodyWith(context, struct {
        fn f(ctx: @TypeOf(context), b: *BlockBuild) !void {
            try ctx.self.evaluate(OperationShapeHook, .{ b, ctx.shape });
        }
    }.f);
}

fn writeOperationFuncError(
    arena: Allocator,
    symbols: *SymbolsProvider,
    bld: *ContainerBuild,
    op_name: []const u8,
    op_errors: []const SmithyId,
    service_errors: []const SmithyId,
) ![]const u8 {
    const type_name = try std.fmt.allocPrint(arena, "{c}{s}Errors", .{
        std.ascii.toUpper(op_name[0]),
        op_name[1..op_name.len],
    });

    const context = .{ .arena = arena, .symbols = symbols, .service_errors = service_errors, .op_errors = op_errors };
    try bld.public().constant(type_name).assign(bld.x.@"union"().bodyWith(context, struct {
        fn f(ctx: @TypeOf(context), b: *ContainerBuild) !void {
            for (ctx.service_errors) |m| try writeOperationFuncErrorMember(ctx.arena, ctx.symbols, b, m);
            for (ctx.op_errors) |m| try writeOperationFuncErrorMember(ctx.arena, ctx.symbols, b, m);
        }
    }.f));

    return type_name;
}

fn writeOperationFuncErrorMember(
    arena: Allocator,
    symbols: *SymbolsProvider,
    bld: *ContainerBuild,
    member: SmithyId,
) !void {
    const type_name = try symbols.getTypeName(member);
    var shape_name = try symbols.getShapeName(member, .field);
    inline for (.{ "_error", "_exception" }) |suffix| {
        if (std.ascii.endsWithIgnoreCase(shape_name, suffix)) {
            shape_name = shape_name[0 .. shape_name.len - suffix.len];
            break;
        }
    }

    try writeDocComment(arena, symbols, bld, member, true);
    if (type_name.len > 0) {
        try bld.field(shape_name).typing(bld.x.raw(type_name)).end();
    } else {
        try bld.field(shape_name).end();
    }
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
        fn eval(tester: *pipez.PipelineTester, bld: *ContainerBuild) anyerror!void {
            try tester.runTask(OpFuncTest, .{bld});
        }
    }.eval,
        \\pub const OperationErrors = union(enum) {
        \\    service: ServiceError,
        \\    not_found: NotFound,
        \\};
        \\
        \\pub fn operation(self: @This(), input: OperationInput) OperationOutput {
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
        fn eval(tester: *pipez.PipelineTester, bld: *ContainerBuild) anyerror!void {
            try tester.runTask(WriteShape, .{ bld, SmithyId.of("test.serve#Resource") });
        }
    }.eval,
        \\pub const Resource = struct {
        \\    forecast_id: []const u8,
        \\
        \\    pub const OperationErrors = union(enum) {
        \\        service: ServiceError,
        \\        not_found: NotFound,
        \\    };
        \\
        \\    pub fn operation(self: @This(), input: OperationInput) OperationOutput {
        \\        return undefined;
        \\    }
        \\};
        \\
        \\pub const OperationInput = struct {};
        \\
        \\pub const OperationOutput = struct {};
    );
}

fn writeServiceShape(
    self: *const Delegate,
    symbols: *SymbolsProvider,
    bld: *ContainerBuild,
    id: SmithyId,
    service: *const syb.SmithyService,
) !void {
    const service_name = try symbols.getShapeName(id, .type);
    try writeDocComment(self.alloc(), symbols, bld, id, false);
    const context = .{ .self = self, .symbols = symbols, .service = service };
    try bld.public().constant(service_name).assign(
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

    for (service.resources) |rsc_id| try symbols.enqueue(rsc_id);
    for (service.errors) |err_id| try symbols.enqueue(err_id);
}

test "writeServiceShape" {
    try smithyTester(&.{.service}, struct {
        fn eval(tester: *pipez.PipelineTester, bld: *ContainerBuild) anyerror!void {
            try tester.runTask(WriteShape, .{ bld, SmithyId.of("test.serve#Service") });

            const symbols = tester.getService(SymbolsProvider).?;
            try testing.expect(symbols.didVisit(SmithyId.of("test.serve#Resource")));
            try testing.expect(symbols.didVisit(SmithyId.of("test.error#NotFound")));
            try testing.expect(symbols.didVisit(SmithyId.of("test.error#ServiceError")));
        }
    }.eval,
        \\/// Some _service_...
        \\pub const Service = struct {
        \\    pub const OperationErrors = union(enum) {
        \\        service: ServiceError,
        \\        not_found: NotFound,
        \\    };
        \\
        \\    pub fn operation(self: @This(), input: OperationInput) OperationOutput {
        \\        return undefined;
        \\    }
        \\};
        \\
        \\pub const OperationInput = struct {};
        \\
        \\pub const OperationOutput = struct {};
    );
}

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

    try bld.commentMarkdownWith(.doc, md.html.CallbackContext{ .allocator = arena, .html = docs }, md.html.callback);
}

fn smithyTester(
    setup_symbols: []const test_symbols.Case,
    eval: *const fn (tester: *pipez.PipelineTester, bld: *ContainerBuild) anyerror!void,
    expected: []const u8,
) !void {
    var tester = try pipez.PipelineTester.init(.{ .invoker = TEST_INVOKER });
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

const TEST_INVOKER = blk: {
    var builder = pipez.InvokerBuilder{};

    _ = builder.Override(ErrorShapeHook, "Test Error Shape", struct {
        fn f(_: *const Delegate, bld: *ContainerBuild, shape: ErrorShape) anyerror!void {
            try bld.public().constant("source").typing(bld.x.raw("ErrorSource"))
                .assign(bld.x.valueOf(shape.source));

            try bld.public().constant("code").typing(bld.x.typeOf(u10))
                .assign(bld.x.valueOf(shape.code));

            try bld.public().constant("retryable").assign(bld.x.valueOf(shape.retryable));
        }
    }.f, .{});

    _ = builder.Override(OperationShapeHook, "Test Operation Shape", struct {
        fn f(_: *const Delegate, bld: *BlockBuild, _: OperationShape) anyerror!void {
            try bld.returns().raw("undefined").end();
        }
    }.f, .{});

    break :blk builder.consume();
};
