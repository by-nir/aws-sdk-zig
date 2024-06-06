//! Produces Zig source code from a Smithy model.
const std = @import("std");
const fs = std.fs;
const log = std.log;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;
const test_alloc = testing.allocator;
const test_model = @import("testing/model.zig");
const symbols = @import("systems/symbols.zig");
const SmithyId = symbols.SmithyId;
const SmithyType = symbols.SmithyType;
const SmithyModel = symbols.SmithyModel;
const md = @import("codegen/md.zig");
const zig = @import("codegen/zig.zig");
const Writer = @import("codegen/CodegenWriter.zig");
const ExprBuild = zig.ExprBuild;
const BlockBuild = zig.BlockBuild;
const ContainerBuild = zig.ContainerBuild;
const names = @import("utils/names.zig");
const IssuesBag = @import("utils/IssuesBag.zig");
const trt_http = @import("traits/http.zig");
const trt_docs = @import("traits/docs.zig");
const trt_refine = @import("traits/refine.zig");
const trt_behave = @import("traits/behavior.zig");
const trt_constr = @import("traits/constraint.zig");

const Self = @This();

pub const Policy = struct {
    unknown_shape: IssuesBag.PolicyResolution,
    invalid_root: IssuesBag.PolicyResolution,
    shape_codegen_fail: IssuesBag.PolicyResolution,
};

pub const Hooks = struct {
    writeScriptHead: ?*const fn (Allocator, *ContainerBuild, *const SmithyModel) anyerror!void = null,
    uniqueListType: ?*const fn (Allocator, []const u8) anyerror![]const u8 = null,
    writeErrorShape: *const fn (Allocator, *ContainerBuild, *const SmithyModel, ErrorShape) anyerror!void,
    writeServiceHead: ?*const fn (Allocator, *ContainerBuild, *const SmithyModel, *const symbols.SmithyService) anyerror!void = null,
    writeResourceHead: ?*const fn (Allocator, *ContainerBuild, *const SmithyModel, SmithyId, *const symbols.SmithyResource) anyerror!void = null,
    operationReturnType: ?*const fn (Allocator, *const SmithyModel, OperationShape) anyerror!?[]const u8 = null,
    writeOperationBody: *const fn (Allocator, *BlockBuild, *const SmithyModel, OperationShape) anyerror!void,

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
};

arena: Allocator,
hooks: Hooks,
policy: Policy,
issues: *IssuesBag,
model: *const SmithyModel,
service_errors: ?[]const SmithyId = null,
shape_queue: std.DoublyLinkedList(SmithyId) = .{},
shape_visited: std.AutoHashMapUnmanaged(SmithyId, void) = .{},

pub fn writeScript(
    arena: Allocator,
    output: std.io.AnyWriter,
    hooks: Hooks,
    policy: Policy,
    issues: *IssuesBag,
    model: *const SmithyModel,
    root: SmithyId,
) !void {
    var self = Self{
        .arena = arena,
        .hooks = hooks,
        .policy = policy,
        .issues = issues,
        .model = model,
    };

    const context = .{ .self = &self, .root = root };
    const script = try zig.Container.init(arena, context, struct {
        fn f(ctx: @TypeOf(context), bld: *ContainerBuild) !void {
            if (ctx.self.hooks.writeScriptHead) |hook| {
                try hook(ctx.self.arena, bld, ctx.self.model);
            }

            try bld.constant("std").assign(bld.x.import("std"));

            try ctx.self.enqueueShape(ctx.root);
            while (ctx.self.dequeueShape()) |id| try ctx.self.writeShape(bld, id);
        }
    }.f);
    defer script.deinit(arena);

    var writer = Writer.init(arena, output);
    defer writer.deinit();

    try script.write(&writer);
    try writer.breakEmpty(1);
}

test "writeScript" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var buffer = std.ArrayList(u8).init(test_alloc);
    const buffer_writer = buffer.writer().any();
    defer buffer.deinit();

    var model = SmithyModel{};
    try test_model.setupRootAndChild(&model);
    defer model.deinit(test_alloc);

    var issues = IssuesBag.init(test_alloc);
    defer issues.deinit();

    try writeScript(
        arena.allocator(),
        buffer_writer,
        TEST_HOOKS,
        TEST_POLICY,
        &issues,
        &model,
        SmithyId.of("test#Root"),
    );
    try testing.expectEqualStrings(
        \\const std = @import("std");
        \\
        \\pub const Root = []const Child;
        \\
        \\pub const Child = []const i32;
        \\
    , buffer.items);
}

fn writeShape(self: *Self, bld: *ContainerBuild, id: SmithyId) !void {
    const shape = self.model.getShape(id) orelse switch (self.policy.unknown_shape) {
        .skip => {
            try self.issues.add(.{ .codegen_unknown_shape = @intFromEnum(id) });
            return;
        },
        .abort => {
            log.err("Unknown shape: `{}`.", .{id});
            return IssuesBag.PolicyAbortError;
        },
    };

    (switch (shape) {
        .list => |m| self.writeListShape(bld, id, m),
        .map => |m| self.writeMapShape(bld, id, m),
        .str_enum => |m| self.writeStrEnumShape(bld, id, m),
        .int_enum => |m| self.writeIntEnumShape(bld, id, m),
        .tagged_uinon => |m| self.writeUnionShape(bld, id, m),
        .structure => |m| self.writeStructShape(bld, id, m),
        .resource => |t| self.writeResourceShape(bld, id, t),
        .service => |t| self.writeServiceShape(bld, id, t),
        .string => if (trt_constr.Enum.get(self.model, id)) |members|
            self.writeTraitEnumShape(bld, id, members)
        else
            error.InvalidRootShape,
        else => error.InvalidRootShape,
    }) catch |e| {
        const shape_name = self.model.getName(id);
        const name_id: IssuesBag.Issue.NameOrId = if (shape_name) |n|
            .{ .name = n }
        else
            .{ .id = @intFromEnum(id) };
        switch (e) {
            error.InvalidRootShape => switch (self.policy.invalid_root) {
                .skip => {
                    try self.issues.add(.{ .codegen_invalid_root = name_id });
                    return;
                },
                .abort => {
                    if (shape_name) |n|
                        log.err("Invalid root shape: `{s}`.", .{n})
                    else
                        log.err("Invalid root shape: `{}`.", .{id});
                    return IssuesBag.PolicyAbortError;
                },
            },
            else => switch (self.policy.shape_codegen_fail) {
                .skip => {
                    try self.issues.add(.{ .codegen_shape_fail = .{
                        .err = e,
                        .item = name_id,
                    } });
                    return;
                },
                .abort => {
                    if (shape_name) |n|
                        log.err("Shape `{s}` codegen failed: `{s}`.", .{ n, @errorName(e) })
                    else
                        log.err("Shape `{}` codegen failed: `{s}`.", .{ id, @errorName(e) });
                    return IssuesBag.PolicyAbortError;
                },
            },
        }
    };
}

test "writeShape" {
    var tester = try ScriptTester.init();
    defer tester.deinit();

    var model = SmithyModel{};
    try test_model.setupUnit(&model);
    defer model.deinit(test_alloc);

    var self = tester.initCodegen(&model);
    try self.writeShape(tester.build, SmithyId.of("test#Unit"));
    try testing.expectEqualDeep(&.{
        IssuesBag.Issue{ .codegen_invalid_root = .{ .id = @intFromEnum(SmithyId.of("test#Unit")) } },
    }, tester.issues.all());
    try tester.expect("");
}

fn writeListShape(self: *Self, bld: *ContainerBuild, id: SmithyId, memeber: SmithyId) !void {
    const shape_name = try self.model.tryGetName(id);
    const type_name = try self.unwrapShapeName(memeber);
    try self.writeDocComment(bld, id, false);

    const target_exp = if (self.model.hasTrait(id, trt_constr.unique_items_id)) blk: {
        if (self.hooks.uniqueListType) |hook| {
            break :blk bld.x.raw(try hook(self.arena, type_name));
        } else {
            break :blk bld.x.call(
                "*const std.AutoArrayHashMapUnmanaged",
                &.{ bld.x.raw(type_name), bld.x.raw("void") },
            );
        }
    } else if (self.model.hasTrait(id, trt_refine.sparse_id))
        bld.x.typeSlice(false, bld.x.typeOptional(bld.x.raw(type_name)))
    else
        bld.x.typeSlice(false, bld.x.raw(type_name));

    try bld.public().constant(shape_name).assign(target_exp);
}

test "writeListShape" {
    var tester = try ScriptTester.init();
    defer tester.deinit();

    var model = SmithyModel{};
    try test_model.setupList(&model);
    defer model.deinit(test_alloc);

    var self = tester.initCodegen(&model);
    try self.writeShape(tester.build, SmithyId.of("test#List"));
    try self.writeShape(tester.build, SmithyId.of("test#Set"));
    try tester.expect(
        \\pub const List = []const ?i32;
        \\
        \\pub const Set = *const std.AutoArrayHashMapUnmanaged(i32, void);
    );
}

fn writeMapShape(self: *Self, bld: *ContainerBuild, id: SmithyId, memeber: [2]SmithyId) !void {
    const shape_name = try self.model.tryGetName(id);
    const key_name = try self.unwrapShapeName(memeber[0]);
    const val_type = try self.unwrapShapeName(memeber[1]);
    try self.writeDocComment(bld, id, false);

    var value: ExprBuild = bld.x.raw(val_type);
    if (self.model.hasTrait(id, trt_refine.sparse_id))
        value = bld.x.typeOptional(value);

    var fn_name: []const u8 = undefined;
    var args: []const ExprBuild = undefined;
    if (std.mem.eql(u8, key_name, "[]const u8")) {
        fn_name = "*const std.StringArrayHashMapUnmanaged";
        args = &.{value};
    } else {
        fn_name = "*const std.AutoArrayHashMapUnmanaged";
        args = &.{ bld.x.raw(key_name), value };
    }

    try bld.public().constant(shape_name).assign(bld.x.call(fn_name, args));
}

test "writeMapShape" {
    var tester = try ScriptTester.init();
    defer tester.deinit();

    var model = SmithyModel{};
    try test_model.setupMap(&model);
    defer model.deinit(test_alloc);

    var self = tester.initCodegen(&model);
    try self.writeShape(tester.build, SmithyId.of("test#Map"));
    try tester.expect("pub const Map = *const std.AutoArrayHashMapUnmanaged(i32, ?i32);");
}

fn writeStrEnumShape(self: *Self, bld: *ContainerBuild, id: SmithyId, members: []const SmithyId) !void {
    var list = try EnumList.initCapacity(self.arena, members.len);
    defer list.deinit();
    for (members) |m| {
        const name = try self.model.tryGetName(m);
        const value = trt_refine.EnumValue.get(self.model, m);
        list.appendAssumeCapacity(.{
            .value = if (value) |v| v.string else name,
            .field = try names.snakeCase(self.arena, name),
        });
    }
    try self.writeEnumShape(bld, id, list.items);
}

fn writeTraitEnumShape(
    self: *Self,
    bld: *ContainerBuild,
    id: SmithyId,
    members: []const trt_constr.Enum.Member,
) !void {
    var list = try EnumList.initCapacity(self.arena, members.len);
    defer list.deinit();
    for (members) |m| {
        list.appendAssumeCapacity(.{
            .value = m.value,
            .field = try names.snakeCase(self.arena, m.name orelse m.value),
        });
    }
    try self.writeEnumShape(bld, id, list.items);
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

fn writeEnumShape(self: *Self, bld: *ContainerBuild, id: SmithyId, members: []const StrEnumMember) !void {
    const context = .{ .self = self, .members = members };
    const Closures = struct {
        fn shape(ctx: @TypeOf(context), b: *ContainerBuild) !void {
            var literals = std.ArrayList(ExprBuild).init(ctx.self.arena);
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

    const shape_name = try self.model.tryGetName(id);
    try self.writeDocComment(bld, id, false);
    try bld.public().constant(shape_name).assign(
        bld.x.@"union"().bodyWith(context, Closures.shape),
    );
}

test "writeEnumShape" {
    var tester = try ScriptTester.init();
    defer tester.deinit();

    var model = SmithyModel{};
    try test_model.setupEnum(&model);
    defer model.deinit(test_alloc);

    var self = tester.initCodegen(&model);
    try self.writeShape(tester.build, SmithyId.of("test#Enum"));
    try self.writeShape(tester.build, SmithyId.of("test#EnumTrt"));

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
    try tester.expect("pub const Enum = union(enum) {\n" ++ BODY ++
        "\n\n" ++ "pub const EnumTrt = union(enum) {\n" ++ BODY);
}

fn writeIntEnumShape(self: *Self, bld: *ContainerBuild, id: SmithyId, members: []const SmithyId) !void {
    const context = .{ .self = self, .members = members };
    const Closures = struct {
        fn shape(ctx: @TypeOf(context), b: *ContainerBuild) !void {
            for (ctx.members) |m| {
                try b.field(try names.snakeCase(ctx.self.arena, try ctx.self.model.tryGetName(m)))
                    .assign(b.x.valueOf(trt_refine.EnumValue.get(ctx.self.model, m).?.integer));
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

    const shape_name = try self.model.tryGetName(id);
    try self.writeDocComment(bld, id, false);
    try bld.public().constant(shape_name).assign(
        bld.x.@"enum"().typing(bld.x.typeOf(i32)).bodyWith(context, Closures.shape),
    );
}

test "writeIntEnumShape" {
    var tester = try ScriptTester.init();
    defer tester.deinit();

    var model = SmithyModel{};
    try test_model.setupIntEnum(&model);
    defer model.deinit(test_alloc);

    var self = tester.initCodegen(&model);
    try self.writeShape(tester.build, SmithyId.of("test#IntEnum"));
    try tester.expect(
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

fn writeUnionShape(self: *Self, bld: *ContainerBuild, id: SmithyId, members: []const SmithyId) !void {
    const shape_name = try self.model.tryGetName(id);
    try self.writeDocComment(bld, id, false);

    const context = .{ .self = self, .members = members };
    try bld.public().constant(shape_name).assign(
        bld.x.@"union"().bodyWith(context, struct {
            fn f(ctx: @TypeOf(context), b: *ContainerBuild) !void {
                for (ctx.members) |m| {
                    const shape = try ctx.self.unwrapShapeName(m);
                    const name = try names.snakeCase(
                        ctx.self.arena,
                        try ctx.self.model.tryGetName(m),
                    );

                    if (shape.len > 0) {
                        try b.field(name).typing(b.x.raw(shape)).end();
                    } else {
                        try b.field(name).end();
                    }
                }
            }
        }.f),
    );
}

test "writeUnionShape" {
    var tester = try ScriptTester.init();
    defer tester.deinit();

    var model = SmithyModel{};
    try test_model.setupUnion(&model);
    defer model.deinit(test_alloc);

    var self = tester.initCodegen(&model);
    try self.writeShape(tester.build, SmithyId.of("test#Union"));
    try tester.expect(
        \\pub const Union = union(enum) {
        \\    foo,
        \\    bar: i32,
        \\    baz: []const u8,
        \\};
    );
}

fn writeStructShape(self: *Self, bld: *ContainerBuild, id: SmithyId, members: []const SmithyId) !void {
    const shape_name = try self.model.tryGetName(id);
    try self.writeDocComment(bld, id, false);

    const context = .{ .self = self, .id = id, .members = members };
    try bld.public().constant(shape_name).assign(
        bld.x.@"struct"().bodyWith(context, struct {
            fn f(ctx: @TypeOf(context), b: *ContainerBuild) !void {
                const is_input = ctx.self.model.hasTrait(ctx.id, trt_refine.input_id);
                try ctx.self.writeStructShapeError(b, ctx.id);
                try ctx.self.writeStructShapeMixin(b, is_input, ctx.id);
                for (ctx.members) |m| try ctx.self.writeStructShapeMember(b, is_input, m);
            }
        }.f),
    );
}

fn writeStructShapeError(self: *Self, bld: *ContainerBuild, id: SmithyId) !void {
    const source = trt_refine.Error.get(self.model, id) orelse return;
    try self.hooks.writeErrorShape(self.arena, bld, self.model, .{
        .id = id,
        .source = source,
        .retryable = self.model.hasTrait(id, trt_behave.retryable_id),
        .code = trt_http.HttpError.get(self.model, id) orelse if (source == .client) 400 else 500,
    });
}

fn writeStructShapeMixin(self: *Self, bld: *ContainerBuild, is_input: bool, id: SmithyId) !void {
    const mixins = self.model.getMixins(id) orelse return;
    for (mixins) |mix_id| {
        try self.writeStructShapeMixin(bld, is_input, mix_id);
        const mixin = (try self.model.tryGetShape(mix_id)).structure;
        for (mixin) |m| {
            try self.writeStructShapeMember(bld, is_input, m);
        }
    }
}

fn writeStructShapeMember(self: *Self, bld: *ContainerBuild, is_input: bool, id: SmithyId) !void {
    // https://smithy.io/2.0/spec/aggregate-types.html#structure-member-optionality
    const optional: bool = if (is_input) true else if (self.model.getTraits(id)) |bag| blk: {
        break :blk bag.has(trt_refine.client_optional_id) or
            !(bag.has(trt_refine.required_id) or bag.has(trt_refine.Default.id));
    } else true;

    const shape_name = try names.snakeCase(self.arena, try self.model.tryGetName(id));
    var type_expr = bld.x.raw(try self.unwrapShapeName(id));
    if (optional) type_expr = bld.x.typeOptional(type_expr);

    try self.writeDocComment(bld, id, true);
    const field = bld.field(shape_name).typing(type_expr);
    const assign: ?ExprBuild = blk: {
        if (optional) break :blk bld.x.valueOf(null);
        if (trt_refine.Default.get(self.model, id)) |json| {
            break :blk switch (try self.unwrapShapeType(id)) {
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
    var tester = try ScriptTester.init();
    defer tester.deinit();

    var model = SmithyModel{};
    try test_model.setupStruct(&model);
    try test_model.setupError(&model);
    defer model.deinit(test_alloc);

    var self = tester.initCodegen(&model);
    try self.writeShape(tester.build, SmithyId.of("test#Struct"));
    try self.writeShape(tester.build, SmithyId.of("test#Error"));
    try tester.expect(
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

fn writeOperationShapes(self: *Self, bld: *ContainerBuild, id: SmithyId) !void {
    const operation = (try self.model.tryGetShape(id)).operation;

    if (operation.input) |in_id| {
        const members = (try self.model.tryGetShape(in_id)).structure;
        try self.writeStructShape(bld, in_id, members);
    }

    if (operation.output) |out_id| {
        const members = (try self.model.tryGetShape(out_id)).structure;
        try self.writeStructShape(bld, out_id, members);
    }

    for (operation.errors) |err_id| {
        // We don't write directly since an error may be used by multiple operations.
        try self.enqueueShape(err_id);
    }
}

test "writeOperationShapes" {
    var tester = try ScriptTester.init();
    defer tester.deinit();

    var model = SmithyModel{};
    try test_model.setupServiceShapes(&model);
    defer model.deinit(test_alloc);

    var self = tester.initCodegen(&model);
    try self.writeOperationShapes(tester.build, SmithyId.of("test.serve#Operation"));
    try tester.expect(
        \\pub const OperationInput = struct {};
        \\
        \\pub const OperationOutput = struct {};
    );
    const node = self.shape_queue.first.?;
    try testing.expectEqual(null, node.next);
    try testing.expectEqual(SmithyId.of("test.error#NotFound"), node.data);
}

fn writeOperationFunc(self: *Self, bld: *ContainerBuild, id: SmithyId) !void {
    const common_errors = try self.getServiceErrors();
    const operation = (try self.model.tryGetShape(id)).operation;
    const op_name = try names.camelCase(self.arena, try self.model.tryGetName(id));

    const errors_type = if (operation.errors.len + common_errors.len > 0)
        try self.writeOperationFuncError(bld, op_name, operation.errors, common_errors)
    else
        null;

    const shape_input = if (operation.input) |d| Hooks.OperationShape.Input{
        .identifier = "input",
        .type = try self.model.tryGetName(d),
    } else null;
    const shape_output = if (operation.output) |d|
        try self.model.tryGetName(d)
    else
        null;
    const shape = Hooks.OperationShape{
        .id = id,
        .input = shape_input,
        .output_type = shape_output,
        .errors_type = errors_type,
    };
    const return_type = if (self.hooks.operationReturnType) |hook| blk: {
        const result = try hook(self.arena, self.model, shape);
        break :blk if (result) |s| bld.x.raw(s) else bld.x.typeOf(void);
    } else if (shape_output) |s|
        bld.x.raw(s)
    else
        bld.x.typeOf(void);

    const context = .{ .self = self, .shape = shape };
    const func1 = bld.public().function(op_name).arg("self", bld.x.This());
    const func2 = if (shape_input) |input| func1.arg(input.identifier, bld.x.raw(input.type)) else func1;
    try func2.returns(return_type).bodyWith(context, struct {
        fn f(ctx: @TypeOf(context), b: *BlockBuild) !void {
            try ctx.self.hooks.writeOperationBody(ctx.self.arena, b, ctx.self.model, ctx.shape);
        }
    }.f);
}

fn writeOperationFuncError(
    self: *Self,
    bld: *ContainerBuild,
    op_name: []const u8,
    op_errors: []const SmithyId,
    common_errors: []const SmithyId,
) ![]const u8 {
    const type_name = try std.fmt.allocPrint(self.arena, "{c}{s}Errors", .{
        std.ascii.toUpper(op_name[0]),
        op_name[1..op_name.len],
    });

    const context = .{ .self = self, .common_errors = common_errors, .op_errors = op_errors };
    try bld.public().constant(type_name).assign(bld.x.@"union"().bodyWith(context, struct {
        fn f(ctx: @TypeOf(context), b: *ContainerBuild) !void {
            for (ctx.common_errors) |m| try ctx.self.writeOperationFuncErrorMember(b, m);
            for (ctx.op_errors) |m| try ctx.self.writeOperationFuncErrorMember(b, m);
        }
    }.f));

    return type_name;
}

fn writeOperationFuncErrorMember(self: *Self, bld: *ContainerBuild, member: SmithyId) !void {
    var field_name = try self.model.tryGetName(member);
    inline for (.{ "error", "exception" }) |suffix| {
        if (std.ascii.endsWithIgnoreCase(field_name, suffix)) {
            field_name = field_name[0 .. field_name.len - suffix.len];
            break;
        }
    }
    field_name = try names.snakeCase(self.arena, field_name);

    const type_name = try self.unwrapShapeName(member);
    try self.writeDocComment(bld, member, true);
    if (type_name.len > 0) {
        try bld.field(field_name).typing(bld.x.raw(type_name)).end();
    } else {
        try bld.field(field_name).end();
    }
}

test "writeOperationFunc" {
    var tester = try ScriptTester.init();
    defer tester.deinit();

    var model = SmithyModel{};
    try test_model.setupServiceShapes(&model);
    defer model.deinit(test_alloc);

    var self = tester.initCodegen(&model);
    try self.writeOperationFunc(tester.build, SmithyId.of("test.serve#Operation"));
    try tester.expect(
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
    self: *Self,
    bld: *ContainerBuild,
    id: SmithyId,
    resource: *const symbols.SmithyResource,
) !void {
    const LIFECYCLE_OPS = &.{ "create", "put", "read", "update", "delete", "list" };
    const resource_name = try self.model.tryGetName(id);
    const context = .{ .self = self, .id = id, .resource = resource };
    try bld.public().constant(resource_name).assign(bld.x.@"struct"().bodyWith(context, struct {
        fn f(ctx: @TypeOf(context), b: *ContainerBuild) !void {
            if (ctx.self.hooks.writeResourceHead) |hook| {
                try hook(ctx.self.arena, b, ctx.self.model, ctx.id, ctx.resource);
            }
            for (ctx.resource.identifiers) |d| {
                try ctx.self.writeDocComment(b, d.shape, true);
                const name = try names.snakeCase(ctx.self.arena, d.name);
                try b.field(name).typing(b.x.raw(try ctx.self.unwrapShapeName(d.shape))).end();
            }

            inline for (LIFECYCLE_OPS) |field| {
                if (@field(ctx.resource, field)) |op_id| {
                    try ctx.self.writeOperationFunc(b, op_id);
                }
            }
            for (ctx.resource.operations) |op_id| try ctx.self.writeOperationFunc(b, op_id);
            for (ctx.resource.collection_ops) |op_id| try ctx.self.writeOperationFunc(b, op_id);
        }
    }.f));

    inline for (LIFECYCLE_OPS) |field| {
        if (@field(resource, field)) |op_id| {
            try self.writeOperationShapes(bld, op_id);
        }
    }
    for (resource.operations) |op_id| try self.writeOperationShapes(bld, op_id);
    for (resource.collection_ops) |op_id| try self.writeOperationShapes(bld, op_id);
    for (resource.resources) |rsc_id| try self.enqueueShape(rsc_id);
}

test "writeResourceShape" {
    var tester = try ScriptTester.init();
    defer tester.deinit();

    var model = SmithyModel{};
    try test_model.setupServiceShapes(&model);
    defer model.deinit(test_alloc);

    var self = tester.initCodegen(&model);
    try self.writeShape(tester.build, SmithyId.of("test.serve#Resource"));
    try tester.expect(
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
    self: *Self,
    bld: *ContainerBuild,
    id: SmithyId,
    service: *const symbols.SmithyService,
) !void {
    // Cache errors
    if (self.service_errors == null) self.service_errors = service.errors;

    const service_name = try self.model.tryGetName(id);
    try self.writeDocComment(bld, id, false);
    const context = .{ .self = self, .service = service };
    try bld.public().constant(service_name).assign(
        bld.x.@"struct"().bodyWith(context, struct {
            fn f(ctx: @TypeOf(context), b: *ContainerBuild) !void {
                if (ctx.self.hooks.writeServiceHead) |hook| {
                    try hook(ctx.self.arena, b, ctx.self.model, ctx.service);
                }
                for (ctx.service.operations) |op_id| {
                    try ctx.self.writeOperationFunc(b, op_id);
                }
            }
        }.f),
    );

    for (service.operations) |op_id| {
        try self.writeOperationShapes(bld, op_id);
    }

    for (service.resources) |rsc_id| try self.enqueueShape(rsc_id);
    for (service.errors) |err_id| try self.enqueueShape(err_id);
}

test "writeServiceShape" {
    var tester = try ScriptTester.init();
    defer tester.deinit();

    var model = SmithyModel{};
    try test_model.setupServiceShapes(&model);
    defer model.deinit(test_alloc);

    var self = tester.initCodegen(&model);
    try self.writeShape(tester.build, SmithyId.of("test.serve#Service"));
    try tester.expect(
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

    try testing.expectEqual(3, self.shape_visited.count());
    try testing.expect(self.shape_visited.contains(SmithyId.of("test.serve#Resource")));
    try testing.expect(self.shape_visited.contains(SmithyId.of("test.error#NotFound")));
    try testing.expect(self.shape_visited.contains(SmithyId.of("test.error#ServiceError")));

    try testing.expectEqualDeep(&.{SmithyId.of("test.error#ServiceError")}, self.service_errors);
}

fn writeDocComment(self: *Self, bld: *ContainerBuild, id: SmithyId, target_fallback: bool) !void {
    var docs = trt_docs.Documentation.get(self.model, id);
    if (target_fallback and docs == null) if (self.model.getShape(id)) |shape| {
        switch (shape) {
            .target => |t| docs = trt_docs.Documentation.get(self.model, t),
            else => {},
        }
    };

    const context = .{ .arena = self.arena, .html = docs orelse return };
    try bld.commentMarkdownWith(.doc, context, struct {
        fn f(ctx: @TypeOf(context), b: *md.Document.Build) !void {
            try md.convertHtml(ctx.arena, b, ctx.html);
        }
    }.f);
}

fn unwrapShapeName(self: *Self, id: SmithyId) ![]const u8 {
    return switch (id) {
        .str_enum, .int_enum, .list, .map, .structure, .tagged_uinon, .operation, .resource, .service, .apply => unreachable,
        // By this point a document should have been parsed into a meaningful type:
        .document => error.UnexpectedDocumentShape,
        // Union shape generator assumes a unit is an empty string:
        .unit => "",
        .boolean => "bool",
        .byte => "i8",
        .short => "i16",
        .integer => "i32",
        .long => "i64",
        .float => "f32",
        .double => "f64",
        .timestamp => "u64",
        .string, .blob => "[]const u8",
        .big_integer, .big_decimal => "[]const u8",
        _ => |t| blk: {
            const shape = try self.model.tryGetShape(t);
            break :blk switch (shape) {
                .target => |target| self.unwrapShapeName(target),
                // zig fmt: off
                inline .unit, .blob, .boolean, .string, .byte, .short, .integer, .long,
                .float, .double, .big_integer, .big_decimal, .timestamp, .document =>
                    |_, g| self.unwrapShapeName(std.enums.nameCast(SmithyId, g)),
                // zig fmt: on
                else => {
                    try self.enqueueShape(t);
                    break :blk self.model.tryGetName(t);
                },
            };
        },
    };
}

fn unwrapShapeType(self: *Self, id: SmithyId) !SmithyType {
    return switch (id) {
        // zig fmt: off
        inline .unit, .blob, .boolean, .string, .byte, .short, .integer, .long,
        .float, .double, .big_integer, .big_decimal, .timestamp, .document =>
            |t| std.enums.nameCast(SmithyType, t),
        // zig fmt: on
        else => switch (try self.model.tryGetShape(id)) {
            .target => |t| self.unwrapShapeType(t),
            else => |t| t,
        },
    };
}

fn getServiceErrors(self: *Self) ![]const SmithyId {
    if (self.service_errors) |e| {
        return e;
    } else {
        const shape = try self.model.tryGetShape(self.model.service);
        const errors = shape.service.errors;
        self.service_errors = errors;
        return errors;
    }
}

test "getServiceErrors" {
    var model = SmithyModel{};
    try test_model.setupServiceShapes(&model);
    defer model.deinit(test_alloc);

    var self = Self{
        .arena = test_alloc,
        .hooks = TEST_HOOKS,
        .policy = TEST_POLICY,
        .model = &model,
        .issues = undefined,
    };
    defer self.shape_visited.deinit(test_alloc);

    const expected = .{SmithyId.of("test.error#ServiceError")};
    try testing.expectEqualDeep(&expected, try self.getServiceErrors());
    try testing.expectEqualDeep(&expected, self.service_errors);
}

fn enqueueShape(self: *Self, id: SmithyId) !void {
    if (self.shape_visited.contains(id)) return;
    try self.shape_visited.put(self.arena, id, void{});
    const node = try self.arena.create(std.DoublyLinkedList(SmithyId).Node);
    node.data = id;
    self.shape_queue.append(node);
}

fn dequeueShape(self: *Self) ?SmithyId {
    const node = self.shape_queue.popFirst() orelse return null;
    const shape = node.data;
    self.arena.destroy(node);
    return shape;
}

test "shapes queue" {
    var self = Self{
        .arena = test_alloc,
        .hooks = TEST_HOOKS,
        .policy = TEST_POLICY,
        .model = undefined,
        .issues = undefined,
    };
    defer self.shape_visited.deinit(test_alloc);

    try self.enqueueShape(SmithyId.of("A"));
    try testing.expectEqualDeep(SmithyId.of("A"), self.dequeueShape());
    try self.enqueueShape(SmithyId.of("A"));
    try testing.expectEqual(null, self.dequeueShape());
    try self.enqueueShape(SmithyId.of("B"));
    try self.enqueueShape(SmithyId.of("C"));
    try testing.expectEqualDeep(SmithyId.of("B"), self.dequeueShape());
    try testing.expectEqualDeep(SmithyId.of("C"), self.dequeueShape());
    try testing.expectEqual(null, self.dequeueShape());
}

const TEST_POLICY = Policy{
    .unknown_shape = .skip,
    .invalid_root = .skip,
    .shape_codegen_fail = .skip,
};

const TEST_HOOKS = Hooks{
    .writeErrorShape = hookErrorShape,
    .writeOperationBody = hookOperationBody,
};

fn hookErrorShape(_: Allocator, bld: *ContainerBuild, _: *const SmithyModel, shape: Hooks.ErrorShape) !void {
    try bld.public().constant("source").typing(bld.x.raw("ErrorSource"))
        .assign(bld.x.valueOf(shape.source));

    try bld.public().constant("code").typing(bld.x.typeOf(u10))
        .assign(bld.x.valueOf(shape.code));

    try bld.public().constant("retryable").assign(bld.x.valueOf(shape.retryable));
}

fn hookOperationBody(_: Allocator, bld: *BlockBuild, _: *const SmithyModel, _: Hooks.OperationShape) !void {
    try bld.returns().raw("undefined").end();
}

const ScriptTester = struct {
    did_end: bool = false,
    arena: *std.heap.ArenaAllocator,
    build: *ContainerBuild,
    issues: *IssuesBag,

    pub fn init() !ScriptTester {
        const arena = try test_alloc.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(test_alloc);
        errdefer {
            arena.deinit();
            test_alloc.destroy(arena);
        }

        const build = try test_alloc.create(ContainerBuild);
        errdefer test_alloc.destroy(build);
        build.* = ContainerBuild.init(test_alloc);
        errdefer build.deinit();

        const issues = try test_alloc.create(IssuesBag);
        errdefer test_alloc.destroy(build);
        issues.* = IssuesBag.init(test_alloc);

        return .{
            .arena = arena,
            .build = build,
            .issues = issues,
        };
    }

    pub fn deinit(self: *ScriptTester) void {
        if (!self.did_end) self.build.deinit();
        test_alloc.destroy(self.build);

        self.arena.deinit();
        test_alloc.destroy(self.arena);

        self.issues.deinit();
        test_alloc.destroy(self.issues);
    }

    pub fn initCodegen(self: *ScriptTester, model: *const SmithyModel) Self {
        return Self{
            .arena = self.arena.allocator(),
            .hooks = TEST_HOOKS,
            .policy = TEST_POLICY,
            .model = model,
            .issues = self.issues,
        };
    }

    pub fn expect(self: *ScriptTester, comptime expected: []const u8) !void {
        const script = try self.build.consume();
        self.did_end = true;
        defer script.deinit(test_alloc);

        try Writer.expectValue(expected, script);
    }
};
