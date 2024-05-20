//! Produces Zig source code from a Smithy model.
const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;
const test_alloc = testing.allocator;
const test_model = @import("tests/model.zig");
const syb_id = @import("symbols/identity.zig");
const SmithyId = syb_id.SmithyId;
const SmithyType = syb_id.SmithyType;
const syb_shape = @import("symbols/shapes.zig");
const SmithyModel = syb_shape.SmithyModel;
const Script = @import("generate/Zig.zig");
const names = @import("utils/names.zig");
const StackWriter = @import("utils/StackWriter.zig");
const trt_http = @import("prelude/http.zig");
const trt_docs = @import("prelude/docs.zig");
const trt_refine = @import("prelude/refine.zig");
const trt_behave = @import("prelude/behavior.zig");
const trt_constr = @import("prelude/constraint.zig");

const Self = @This();

pub const Policy = struct {};

pub const Hooks = struct {
    writeScriptHead: ?*const fn (Allocator, *Script) anyerror!void = null,
    uniqueListType: ?*const fn (Allocator, Script.Expr) anyerror!Script.Expr = null,
    writeErrorShape: *const fn (Allocator, *Script, *const SmithyModel, ErrorShape) anyerror!void,
    writeServiceHead: ?*const fn (Allocator, *Script, *const SmithyModel, *const syb_shape.SmithyService) anyerror!void = null,
    writeResourceHead: ?*const fn (Allocator, *Script, *const SmithyModel, SmithyId, *const syb_shape.SmithyResource) anyerror!void = null,
    operationReturnType: ?*const fn (Allocator, *const SmithyModel, OperationShape) anyerror!?Script.Expr = null,
    writeOperationBody: *const fn (Allocator, *Script.Scope, *const SmithyModel, OperationShape) anyerror!void,

    pub const ErrorShape = struct {
        id: SmithyId,
        source: trt_refine.Error.Source,
        code: u10,
        retryable: bool,
    };

    pub const OperationShape = struct {
        id: SmithyId,
        input: ?struct { identifier: Script.Identifier, type: Script.Expr },
        output_type: ?Script.Expr,
        errors_type: ?Script.Expr,
    };
};

arena: Allocator,
hooks: Hooks,
model: *const SmithyModel,
service_errors: ?[]const SmithyId = null,
shape_queue: std.DoublyLinkedList(SmithyId) = .{},
shape_visited: std.AutoHashMapUnmanaged(SmithyId, void) = .{},

pub fn writeScript(
    arena: Allocator,
    hooks: Hooks,
    model: *const SmithyModel,
    output: std.io.AnyWriter,
    root: SmithyId,
) !void {
    var self = Self{
        .arena = arena,
        .hooks = hooks,
        .model = model,
    };

    var writer = StackWriter.init(self.arena, output, .{});
    var script = try Script.init(&writer, null);

    if (self.hooks.writeScriptHead) |hook| {
        try hook(self.arena, &script);
    }

    const imp_std = try script.import("std");
    assert(std.mem.eql(u8, imp_std.name, "_imp_std"));

    try self.enqueueShape(root);
    while (self.dequeueShape()) |id| {
        try self.writeScriptShape(&script, id);
    }

    // End script with empty line (after imports)
    try script.writer.deferLineBreak(.self, 1);
    try script.end();
}

test "writeScript" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var buffer = std.ArrayList(u8).init(test_alloc);
    const buffer_writer = buffer.writer().any();
    defer buffer.deinit();

    var model = SmithyModel{};
    try test_model.setupShapeQueue(&model);
    defer model.deinit(test_alloc);

    try writeScript(
        arena.allocator(),
        TEST_HOOKS,
        &model,
        buffer_writer,
        SmithyId.of("test#Root"),
    );
    try testing.expectEqualStrings(
        \\pub const Root = []const Child;
        \\pub const Child = []const i32;
        \\
        \\const _imp_std = @import("std");
        \\
    , buffer.items);
}

fn writeScriptShape(self: *Self, script: *Script, id: SmithyId) !void {
    const shape = try self.model.tryGetShape(id);
    switch (shape) {
        .list => |m| try self.writeListShape(script, id, m),
        .map => |m| try self.writeMapShape(script, id, m),
        .str_enum => |m| try self.writeStrEnumShape(script, id, m),
        .int_enum => |m| try self.writeIntEnumShape(script, id, m),
        .tagged_uinon => |m| try self.writeUnionShape(script, id, m),
        .structure => |m| try self.writeStructShape(script, id, m),
        .service => |t| try self.writeServiceShape(script, id, t),
        .resource => |t| try self.writeResourceShape(script, id, t),
        .string => {
            return if (trt_constr.Enum.get(self.model, id)) |members|
                self.writeTraitEnumShape(script, id, members)
            else
                error.InvalidRootShape;
        },
        else => return error.InvalidRootShape,
    }
}

test "writeScriptShape" {
    var tester = try ScriptTester.init();
    defer tester.deinit();

    var model = SmithyModel{};
    try test_model.setupUnit(&model);
    defer model.deinit(test_alloc);

    var self = Self{
        .arena = tester.arena.allocator(),
        .hooks = TEST_HOOKS,
        .model = &model,
    };
    try testing.expectError(
        error.InvalidRootShape,
        self.writeScriptShape(tester.script, SmithyId.of("test#Unit")),
    );
    try tester.expect("");
}

fn writeListShape(self: *Self, script: *Script, id: SmithyId, memeber: SmithyId) !void {
    const shape_name = try self.model.tryGetName(id);
    const target_type = Script.Expr{ .raw = try self.unwrapShapeName(memeber) };
    try self.writeDocComment(script, id, false);
    if (self.model.hasTrait(id, trt_constr.unique_items_id)) {
        const target = if (self.hooks.uniqueListType) |hook|
            try hook(self.arena, target_type)
        else
            Script.Expr.call(
                "*const _imp_std.AutoArrayHashMapUnmanaged",
                &.{ target_type, .{ .raw = "void" } },
            );
        _ = try script.variable(
            .{ .is_public = true },
            .{ .identifier = .{ .name = shape_name } },
            target,
        );
    } else {
        const target = if (self.model.hasTrait(id, trt_refine.sparse_id))
            Script.Expr{ .typ_optional = &target_type }
        else
            target_type;
        _ = try script.variable(
            .{ .is_public = true },
            .{ .identifier = .{ .name = shape_name } },
            .{ .typ_slice = .{ .type = &target } },
        );
    }
}

test "writeListShape" {
    var tester = try ScriptTester.init();
    defer tester.deinit();

    var model = SmithyModel{};
    try test_model.setupList(&model);
    defer model.deinit(test_alloc);

    var self = Self{
        .arena = tester.arena.allocator(),
        .hooks = TEST_HOOKS,
        .model = &model,
    };
    try self.writeScriptShape(tester.script, SmithyId.of("test#List"));
    try self.writeScriptShape(tester.script, SmithyId.of("test#Set"));
    try tester.expect(
        \\pub const List = []const ?i32;
        \\pub const Set = *const _imp_std.AutoArrayHashMapUnmanaged(i32, void);
    );
}

fn writeMapShape(self: *Self, script: *Script, id: SmithyId, memeber: [2]SmithyId) !void {
    const shape_name = try self.model.tryGetName(id);
    const key_name = try self.unwrapShapeName(memeber[0]);
    const val_type = try self.unwrapShapeName(memeber[1]);
    const value: Script.Expr = if (self.model.hasTrait(id, trt_refine.sparse_id))
        .{ .raw_seq = &.{ "?", val_type } }
    else
        .{ .raw = val_type };

    try self.writeDocComment(script, id, false);
    _ = try script.variable(
        .{ .is_public = true },
        .{ .identifier = .{ .name = shape_name } },
        if (std.mem.eql(u8, key_name, "[]const u8"))
            Script.Expr.call(
                "*const _imp_std.StringArrayHashMapUnmanaged",
                &.{value},
            )
        else
            Script.Expr.call(
                "*const _imp_std.AutoArrayHashMapUnmanaged",
                &.{ .{ .raw = key_name }, value },
            ),
    );
}

test "writeMapShape" {
    var tester = try ScriptTester.init();
    defer tester.deinit();

    var model = SmithyModel{};
    try test_model.setupMap(&model);
    defer model.deinit(test_alloc);

    var self = Self{
        .arena = tester.arena.allocator(),
        .hooks = TEST_HOOKS,
        .model = &model,
    };
    try self.writeScriptShape(tester.script, SmithyId.of("test#Map"));
    try tester.expect("pub const Map = *const _imp_std.AutoArrayHashMapUnmanaged(i32, ?i32);");
}

fn writeStrEnumShape(self: *Self, script: *Script, id: SmithyId, members: []const SmithyId) !void {
    var list = try std.ArrayList(StrEnumMember).initCapacity(self.arena, members.len);
    defer list.deinit();
    for (members) |m| {
        const name = try self.model.tryGetName(m);
        const value = trt_refine.EnumValue.get(self.model, m);
        list.appendAssumeCapacity(.{
            .value = if (value) |v| v.string else name,
            .field = try names.snakeCase(self.arena, name),
        });
    }
    try self.writeEnumShape(script, id, list.items);
}

fn writeTraitEnumShape(self: *Self, script: *Script, id: SmithyId, members: []const trt_constr.Enum.Member) !void {
    var list = try std.ArrayList(StrEnumMember).initCapacity(self.arena, members.len);
    defer list.deinit();
    for (members) |m| {
        list.appendAssumeCapacity(.{
            .value = m.value,
            .field = try names.snakeCase(self.arena, m.name orelse m.value),
        });
    }
    try self.writeEnumShape(script, id, list.items);
}

const StrEnumMember = struct {
    value: []const u8,
    field: []const u8,

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print(".{{ \"{s}\", .{s} }}", .{ self.value, self.field });
    }
};

fn writeEnumShape(self: *Self, script: *Script, id: SmithyId, members: []const StrEnumMember) !void {
    const shape_name = try self.model.tryGetName(id);
    try self.writeDocComment(script, id, false);
    var scope = try script.declare(.{ .name = shape_name }, .{
        .is_public = true,
        .type = .{ .TaggedUnion = null },
    });

    var doc = try scope.comment(.doc);
    try doc.paragraph("Used for backwards compatibility when adding new values.");
    try doc.end();
    _ = try scope.field(.{ .name = "UNKNOWN", .type = .typ_string });

    for (members) |member| {
        _ = try scope.field(.{ .name = member.field, .type = null });
    }

    const imp_std = try scope.import("std");
    const map_type = try scope.variable(.{}, .{
        .identifier = .{ .name = "ParseMap" },
    }, Script.Expr.call(
        try imp_std.child(self.arena, "StaticStringMap"),
        &.{.{ .raw = "@This()" }},
    ));

    const map_values = blk: {
        var vals = std.ArrayList(StrEnumMember).init(self.arena);
        defer vals.deinit();

        const map_list = try scope.preRenderMultiline(self.arena, StrEnumMember, members, ".{", "}");
        defer self.arena.free(map_list);

        break :blk try scope.variable(.{}, .{
            .identifier = .{ .name = "parse_map" },
        }, Script.Expr.call(
            try map_type.child(self.arena, "initComptime"),
            &.{.{ .raw = map_list }},
        ));
    };

    var blk = try scope.function(.{
        .is_public = true,
    }, .{
        .identifier = .{ .name = "parse" },
        .parameters = &.{
            .{ .identifier = .{ .name = "value" }, .type = .typ_string },
        },
        .return_type = .typ_This,
    });
    try blk.prefix(.ret).exprFmt("{}.get(value) orelse .{{ .UNKNOWN = value }}", .{map_values});
    try blk.end();

    blk = try scope.function(.{
        .is_public = true,
    }, .{
        .identifier = .{ .name = "serialize" },
        .parameters = &.{Script.param_self},
        .return_type = .typ_string,
    });
    const swtch = try blk.prefix(.ret).switchCtrl(.{ .raw = "self" });
    var prong = try swtch.prong(&.{
        .{ .value = .{ .name = "UNKNOWN" } },
    }, .{
        .payload = &.{.{ .name = "s" }},
    }, .inlined);
    try prong.expr(.{ .raw = "s" });
    try prong.end();
    for (members) |member| {
        prong = try swtch.prong(&.{
            .{ .value = .{ .name = member.field } },
        }, .{}, .inlined);
        try prong.expr(Script.Expr.val(member.value));
        try prong.end();
    }
    try swtch.end();
    try scope.writer.writeByte(';');
    try blk.end();

    try scope.end();
}

test "writeEnumShape" {
    var tester = try ScriptTester.init();
    defer tester.deinit();

    var model = SmithyModel{};
    try test_model.setupEnum(&model);
    defer model.deinit(test_alloc);

    var self = Self{
        .arena = tester.arena.allocator(),
        .hooks = TEST_HOOKS,
        .model = &model,
    };
    try self.writeScriptShape(tester.script, SmithyId.of("test#Enum"));
    try self.writeScriptShape(tester.script, SmithyId.of("test#EnumTrt"));

    const BODY =
        \\    /// Used for backwards compatibility when adding new values.
        \\    UNKNOWN: []const u8,
        \\    foo_bar,
        \\    baz_qux,
        \\
        \\    const ParseMap = _imp_std.StaticStringMap(@This());
        \\    const parse_map = ParseMap.initComptime(.{
        \\        .{ "FOO_BAR", .foo_bar },
        \\        .{ "baz$qux", .baz_qux },
        \\    });
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

fn writeIntEnumShape(self: *Self, script: *Script, id: SmithyId, members: []const SmithyId) !void {
    const shape_name = try self.model.tryGetName(id);
    try self.writeDocComment(script, id, false);
    var scope = try script.declare(.{ .name = shape_name }, .{
        .is_public = true,
        .type = .{ .Enum = .{ .raw = "i32" } },
    });

    for (members) |m| {
        _ = try scope.field(.{
            .name = try names.snakeCase(self.arena, try self.model.tryGetName(m)),
            .type = null,
            .assign = Script.Expr.val(trt_refine.EnumValue.get(self.model, m).?.integer),
        });
    }

    var doc = try scope.comment(.doc);
    try doc.paragraph("Used for backwards compatibility when adding new values.");
    try doc.end();
    _ = try scope.field(.{ .name = "_", .type = null });

    var blk = try scope.function(.{
        .is_public = true,
    }, .{
        .identifier = .{ .name = "parse" },
        .parameters = &.{
            .{ .identifier = .{ .name = "value" }, .type = Script.Expr.typ(i32) },
        },
        .return_type = .typ_This,
    });
    try blk.prefix(.ret).expr(.{ .raw = "@enumFromInt(value)" });
    try blk.end();

    blk = try scope.function(.{
        .is_public = true,
    }, .{
        .identifier = .{ .name = "serialize" },
        .parameters = &.{Script.param_self},
        .return_type = Script.Expr.typ(i32),
    });
    try blk.prefix(.ret).expr(.{ .raw = "@intFromEnum(self)" });
    try blk.end();

    try scope.end();
}

test "writeIntEnumShape" {
    var tester = try ScriptTester.init();
    defer tester.deinit();

    var model = SmithyModel{};
    try test_model.setupIntEnum(&model);
    defer model.deinit(test_alloc);

    var self = Self{
        .arena = tester.arena.allocator(),
        .hooks = TEST_HOOKS,
        .model = &model,
    };
    try self.writeScriptShape(tester.script, SmithyId.of("test#IntEnum"));
    try tester.expect(
        \\/// An **integer-based** enumeration.
        \\pub const IntEnum = enum(i32) {
        \\    foo_bar = 8,
        \\    baz_qux = 9,
        \\
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

fn writeUnionShape(self: *Self, script: *Script, id: SmithyId, members: []const SmithyId) !void {
    const shape_name = try self.model.tryGetName(id);
    try self.writeDocComment(script, id, false);
    var scope = try script.declare(.{ .name = shape_name }, .{
        .is_public = true,
        .type = .{ .TaggedUnion = null },
    });
    for (members) |m| {
        const shape = self.unwrapShapeName(m) catch |e| {
            scope.deinit();
            return e;
        };
        var name = self.model.tryGetName(m) catch |e| {
            scope.deinit();
            return e;
        };
        name = names.snakeCase(self.arena, name) catch |e| {
            scope.deinit();
            return e;
        };
        _ = scope.field(.{
            .name = name,
            .type = if (shape.len > 0) .{ .raw = shape } else null,
        }) catch |e| {
            scope.deinit();
            return e;
        };
    }
    try scope.end();
}

test "writeUnionShape" {
    var tester = try ScriptTester.init();
    defer tester.deinit();

    var model = SmithyModel{};
    try test_model.setupUnion(&model);
    defer model.deinit(test_alloc);

    var self = Self{
        .arena = tester.arena.allocator(),
        .hooks = TEST_HOOKS,
        .model = &model,
    };
    try self.writeScriptShape(tester.script, SmithyId.of("test#Union"));
    try tester.expect(
        \\pub const Union = union(enum) {
        \\    foo,
        \\    bar: i32,
        \\    baz: []const u8,
        \\};
    );
}

fn writeStructShape(self: *Self, script: *Script, id: SmithyId, members: []const SmithyId) !void {
    const shape_name = try self.model.tryGetName(id);
    const is_input = self.model.hasTrait(id, trt_refine.input_id);
    try self.writeDocComment(script, id, false);
    var scope = try script.declare(.{ .name = shape_name }, .{
        .is_public = true,
        .type = .{ .Struct = null },
    });
    self.writeStructShapeError(&scope, id) catch |e| {
        scope.deinit();
        return e;
    };
    self.writeStructShapeMixin(&scope, is_input, id) catch |e| {
        scope.deinit();
        return e;
    };
    for (members) |m| {
        self.writeStructShapeMember(&scope, is_input, m) catch |e| {
            scope.deinit();
            return e;
        };
    }
    try scope.end();
}

fn writeStructShapeError(self: *Self, script: *Script, id: SmithyId) !void {
    const source = trt_refine.Error.get(self.model, id) orelse return;
    _ = try self.hooks.writeErrorShape(self.arena, script, self.model, .{
        .id = id,
        .source = source,
        .retryable = self.model.hasTrait(id, trt_behave.retryable_id),
        .code = trt_http.HttpError.get(self.model, id) orelse if (source == .client) 400 else 500,
    });
}

fn writeStructShapeMixin(self: *Self, script: *Script, is_input: bool, id: SmithyId) !void {
    const mixins = self.model.getMixins(id) orelse return;
    for (mixins) |mix_id| {
        try self.writeStructShapeMixin(script, is_input, mix_id);
        const mixin = (try self.model.tryGetShape(mix_id)).structure;
        for (mixin) |m| {
            try self.writeStructShapeMember(script, is_input, m);
        }
    }
}

fn writeStructShapeMember(self: *Self, script: *Script, is_input: bool, id: SmithyId) !void {
    // https://smithy.io/2.0/spec/aggregate-types.html#structure-member-optionality
    const optional = if (is_input) true else if (self.model.getTraits(id)) |bag| blk: {
        break :blk bag.has(trt_refine.client_optional_id) or
            !(bag.has(trt_refine.required_id) or bag.has(trt_refine.Default.id));
    } else true;
    const assign: ?Script.Expr = blk: {
        break :blk if (optional)
            .{ .raw = "null" }
        else if (trt_refine.Default.get(self.model, id)) |json|
            switch (try self.unwrapShapeType(id)) {
                .str_enum => Script.Expr{ .val_enum = json.string },
                .int_enum => Script.Expr.call("@enumFromInt", &.{Script.Expr.val(json.integer)}),
                else => .{ .json = json },
            }
        else
            null;
    };

    try self.writeDocComment(script, id, true);
    const type_expr = Script.Expr{ .raw = try self.unwrapShapeName(id) };
    _ = try script.field(.{
        .name = try names.snakeCase(self.arena, try self.model.tryGetName(id)),
        .type = if (optional) .{ .typ_optional = &type_expr } else type_expr,
        .assign = assign,
    });
}

test "writeStructShape" {
    var tester = try ScriptTester.init();
    defer tester.deinit();

    var model = SmithyModel{};
    try test_model.setupStruct(&model);
    try test_model.setupError(&model);
    defer model.deinit(test_alloc);

    var self = Self{
        .arena = tester.arena.allocator(),
        .hooks = TEST_HOOKS,
        .model = &model,
    };
    try self.writeScriptShape(tester.script, SmithyId.of("test#Struct"));
    try self.writeScriptShape(tester.script, SmithyId.of("test#Error"));
    try tester.expect(
        \\pub const Struct = struct {
        \\    mixed: ?bool = null,
        \\
        \\    /// A **struct** member.
        \\    foo_bar: i32,
        \\
        \\    /// An **integer-based** enumeration.
        \\    baz_qux: IntEnum = @enumFromInt(8),
        \\};
        \\
        \\pub const Error = struct {
        \\    pub const source: ErrorSource = .client;
        \\    pub const code: u10 = 429;
        \\    pub const retryable = true;
        \\};
    );
}

fn writeOperationShapes(self: *Self, script: *Script, id: SmithyId) !void {
    const operation = (try self.model.tryGetShape(id)).operation;

    if (operation.input) |in_id| {
        const members = (try self.model.tryGetShape(in_id)).structure;
        try self.writeStructShape(script, in_id, members);
    }

    if (operation.output) |out_id| {
        const members = (try self.model.tryGetShape(out_id)).structure;
        try self.writeStructShape(script, out_id, members);
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

    var self = Self{
        .arena = tester.arena.allocator(),
        .hooks = TEST_HOOKS,
        .model = &model,
    };
    try self.writeOperationShapes(tester.script, SmithyId.of("test.serve#Operation"));
    try tester.expect(
        \\pub const OperationInput = struct {
        \\
        \\};
        \\
        \\pub const OperationOutput = struct {
        \\
        \\};
    );
    const node = self.shape_queue.first.?;
    try testing.expectEqual(null, node.next);
    try testing.expectEqual(SmithyId.of("test.error#NotFound"), node.data);
}

fn writeOperationFunc(self: *Self, script: *Script, id: SmithyId) !void {
    const common_errors = try self.getServiceErrors();
    const operation = (try self.model.tryGetShape(id)).operation;
    const op_name = try names.camelCase(self.arena, try self.model.tryGetName(id));

    var name_buffer: [128]u8 = undefined;
    const errors_type = try self.writeOperationFuncError(
        script,
        name_buffer[0..],
        op_name,
        operation.errors,
        common_errors,
    );

    const shape = Hooks.OperationShape{
        .id = id,
        .input = if (operation.input) |d| .{
            .identifier = .{ .name = "input" },
            .type = .{ .raw = try self.model.tryGetName(d) },
        } else null,
        .output_type = if (operation.output) |d|
            Script.Expr{ .raw = try self.model.tryGetName(d) }
        else
            null,
        .errors_type = errors_type,
    };
    const return_type = if (self.hooks.operationReturnType) |hook|
        try hook(self.arena, self.model, shape)
    else
        shape.output_type;

    var block = try script.function(.{
        .is_public = true,
    }, .{
        .identifier = .{ .name = op_name },
        .parameters = if (shape.input) |input|
            &.{ Script.param_self, .{
                .identifier = input.identifier,
                .type = input.type,
            } }
        else
            &.{Script.param_self},
        .return_type = return_type,
    });
    try self.hooks.writeOperationBody(self.arena, &block, self.model, shape);
    try block.end();
}

fn writeOperationFuncError(
    self: *Self,
    script: *Script,
    buffer: []u8,
    op_name: []const u8,
    op_errors: []const SmithyId,
    common_errors: []const SmithyId,
) !?Script.Expr {
    if (op_errors.len + common_errors.len == 0) return null;

    const suffix = "Errors";
    const total_len = op_name.len + suffix.len;
    assert(total_len <= 128);
    @memcpy(buffer[0..op_name.len], op_name);
    @memcpy(buffer[op_name.len..][0..suffix.len], suffix);
    const type_name = buffer[0..total_len];

    var scope = try script.declare(.{ .name = type_name }, .{
        .is_public = true,
        .type = .{ .TaggedUnion = null },
    });
    for (common_errors) |m| {
        self.writeOperationFuncErrorMember(&scope, m) catch |e| {
            scope.deinit();
            return e;
        };
    }
    for (op_errors) |m| {
        self.writeOperationFuncErrorMember(&scope, m) catch |e| {
            scope.deinit();
            return e;
        };
    }
    try scope.end();

    return Script.Expr{ .raw = type_name };
}

fn writeOperationFuncErrorMember(self: *Self, scope: *Script, member: SmithyId) !void {
    var name = try self.model.tryGetName(member);
    inline for (.{ "error", "exception" }) |suffix| {
        if (std.ascii.endsWithIgnoreCase(name, suffix)) {
            name = name[0 .. name.len - suffix.len];
            break;
        }
    }

    const shape = try self.unwrapShapeName(member);
    try self.writeDocComment(scope, member, true);
    _ = try scope.field(.{
        .name = try names.snakeCase(self.arena, name),
        .type = if (shape.len > 0) .{ .raw = shape } else null,
    });
}

test "writeOperationFunc" {
    var tester = try ScriptTester.init();
    defer tester.deinit();

    var model = SmithyModel{};
    try test_model.setupServiceShapes(&model);
    defer model.deinit(test_alloc);

    var self = Self{
        .arena = tester.arena.allocator(),
        .hooks = TEST_HOOKS,
        .model = &model,
    };
    try self.writeOperationFunc(tester.script, SmithyId.of("test.serve#Operation"));
    try tester.expect(
        \\pub const operationErrors = union(enum) {
        \\    service: ServiceError,
        \\    not_found: NotFound,
        \\};
        \\
        \\pub fn operation(self: @This(), input: OperationInput) OperationOutput {
        \\    return undefined;
        \\}
    );
}

fn writeResourceShape(self: *Self, script: *Script, id: SmithyId, resource: *const syb_shape.SmithyResource) !void {
    const resource_name = try self.model.tryGetName(id);
    var scope = try script.declare(.{ .name = resource_name }, .{
        .is_public = true,
        .type = .{ .Struct = null },
    });
    if (self.hooks.writeResourceHead) |hook| {
        hook(self.arena, &scope, self.model, id, resource) catch |e| {
            scope.deinit();
            return e;
        };
    }
    for (resource.identifiers) |idn| {
        self.writeDocComment(script, id, true) catch |e| {
            scope.deinit();
            return e;
        };
        const name = names.snakeCase(self.arena, idn.name) catch |e| {
            scope.deinit();
            return e;
        };
        _ = scope.field(.{
            .name = name,
            .type = .{ .raw = try self.unwrapShapeName(idn.shape) },
        }) catch |e| {
            scope.deinit();
            return e;
        };
    }
    const lifecycle_ops = &.{ "create", "put", "read", "update", "delete", "list" };
    inline for (lifecycle_ops) |field| {
        if (@field(resource, field)) |op_id| {
            self.writeOperationFunc(&scope, op_id) catch |e| {
                scope.deinit();
                return e;
            };
        }
    }
    for (resource.operations) |op_id| {
        self.writeOperationFunc(&scope, op_id) catch |e| {
            scope.deinit();
            return e;
        };
    }
    for (resource.collection_ops) |op_id| {
        self.writeOperationFunc(&scope, op_id) catch |e| {
            scope.deinit();
            return e;
        };
    }
    try scope.end();

    inline for (lifecycle_ops) |field| {
        if (@field(resource, field)) |op_id| {
            try self.writeOperationShapes(script, op_id);
        }
    }
    for (resource.operations) |op_id| {
        try self.writeOperationShapes(script, op_id);
    }
    for (resource.collection_ops) |op_id| {
        try self.writeOperationShapes(script, op_id);
    }

    for (resource.resources) |rsc_id| try self.enqueueShape(rsc_id);
}

test "writeResourceShape" {
    var tester = try ScriptTester.init();
    defer tester.deinit();

    var model = SmithyModel{};
    try test_model.setupServiceShapes(&model);
    defer model.deinit(test_alloc);

    var self = Self{
        .arena = tester.arena.allocator(),
        .hooks = TEST_HOOKS,
        .model = &model,
    };
    try self.writeScriptShape(tester.script, SmithyId.of("test.serve#Resource"));
    try tester.expect(
        \\pub const Resource = struct {
        \\    forecast_id: []const u8,
        \\
        \\    pub const operationErrors = union(enum) {
        \\        service: ServiceError,
        \\        not_found: NotFound,
        \\    };
        \\
        \\    pub fn operation(self: @This(), input: OperationInput) OperationOutput {
        \\        return undefined;
        \\    }
        \\};
        \\
        \\pub const OperationInput = struct {
        \\
        \\};
        \\
        \\pub const OperationOutput = struct {
        \\
        \\};
    );
}

fn writeServiceShape(self: *Self, script: *Script, id: SmithyId, service: *const syb_shape.SmithyService) !void {
    // Cache errors
    if (self.service_errors == null) self.service_errors = service.errors;

    const service_name = try self.model.tryGetName(id);
    try self.writeDocComment(script, id, false);
    var scope = try script.declare(.{ .name = service_name }, .{
        .is_public = true,
        .type = .{ .Struct = null },
    });
    if (self.hooks.writeServiceHead) |hook| {
        hook(self.arena, &scope, self.model, service) catch |e| {
            scope.deinit();
            return e;
        };
    }
    for (service.operations) |op_id| {
        self.writeOperationFunc(&scope, op_id) catch |e| {
            scope.deinit();
            return e;
        };
    }
    try scope.end();

    for (service.operations) |op_id| {
        self.writeOperationShapes(script, op_id) catch |e| {
            scope.deinit();
            return e;
        };
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

    var self = Self{
        .arena = tester.arena.allocator(),
        .hooks = TEST_HOOKS,
        .model = &model,
    };
    try self.writeScriptShape(tester.script, SmithyId.of("test.serve#Service"));
    try tester.expect(
        \\/// Some _service_...
        \\pub const Service = struct {
        \\    pub const operationErrors = union(enum) {
        \\        service: ServiceError,
        \\        not_found: NotFound,
        \\    };
        \\
        \\    pub fn operation(self: @This(), input: OperationInput) OperationOutput {
        \\        return undefined;
        \\    }
        \\};
        \\
        \\pub const OperationInput = struct {
        \\
        \\};
        \\
        \\pub const OperationOutput = struct {
        \\
        \\};
    );

    try testing.expectEqual(3, self.shape_visited.count());
    try testing.expect(self.shape_visited.contains(SmithyId.of("test.serve#Resource")));
    try testing.expect(self.shape_visited.contains(SmithyId.of("test.error#NotFound")));
    try testing.expect(self.shape_visited.contains(SmithyId.of("test.error#ServiceError")));

    try testing.expectEqualDeep(&.{SmithyId.of("test.error#ServiceError")}, self.service_errors);
}

fn writeDocComment(self: *Self, script: *Script, id: SmithyId, target_fallback: bool) !void {
    var raw_doc = trt_docs.Documentation.get(self.model, id);
    if (target_fallback and raw_doc == null) if (self.model.getShape(id)) |shape| {
        switch (shape) {
            .target => |t| raw_doc = trt_docs.Documentation.get(self.model, t),
            else => {},
        }
    };
    if (raw_doc) |doc| {
        var md = try script.comment(.doc);
        try md.writeSource(doc);
        try md.end();
    }
}

fn unwrapShapeName(self: *Self, id: SmithyId) ![]const u8 {
    return switch (id) {
        .unit => "",
        .boolean => "bool",
        .byte => "i8",
        .short => "i16",
        .integer => "i32",
        .long => "i64",
        .float => "f32",
        .double => "f64",
        .string, .blob, .document => "[]const u8",
        .big_integer, .big_decimal => "[]const u8",
        .timestamp => "u64",
        .str_enum, .int_enum, .list, .map, .structure, .tagged_uinon, .operation, .resource, .service, .apply => unreachable,
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
        .model = &model,
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
        .model = undefined,
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

const TEST_HOOKS = Hooks{
    .writeScriptHead = hookScriptHead,
    .writeErrorShape = hookErrorShape,
    .writeOperationBody = hookOperationBody,
};

fn hookScriptHead(_: Allocator, script: *Script) !void {
    _ = try script.import("std");
}

fn hookErrorShape(_: Allocator, script: *Script, _: *const SmithyModel, shape: Hooks.ErrorShape) !void {
    _ = try script.variable(.{ .is_public = true }, .{
        .identifier = .{ .name = "source" },
        .type = .{ .raw = "ErrorSource" },
    }, Script.Expr.val(shape.source));

    _ = try script.variable(.{ .is_public = true }, .{
        .identifier = .{ .name = "code" },
        .type = Script.Expr.typ(u10),
    }, Script.Expr.val(shape.code));

    _ = try script.variable(.{ .is_public = true }, .{
        .identifier = .{ .name = "retryable" },
    }, Script.Expr.val(shape.retryable));
}

fn hookOperationBody(_: Allocator, body: *Script.Scope, _: *const SmithyModel, _: Hooks.OperationShape) !void {
    try body.prefix(.ret).expr(.{ .raw = "undefined" });
}

const ScriptTester = struct {
    did_end: bool = false,
    arena: *std.heap.ArenaAllocator,
    buffer: *std.ArrayList(u8),
    buffer_writer: *std.ArrayList(u8).Writer,
    writer: *StackWriter,
    script: *Script,

    pub fn init() !ScriptTester {
        const arena = try test_alloc.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(test_alloc);
        errdefer {
            arena.deinit();
            test_alloc.destroy(arena);
        }

        const buffer = try test_alloc.create(std.ArrayList(u8));
        buffer.* = std.ArrayList(u8).init(test_alloc);
        errdefer {
            buffer.deinit();
            test_alloc.destroy(buffer);
        }

        const buffer_writer = try test_alloc.create(std.ArrayList(u8).Writer);
        buffer_writer.* = buffer.writer();
        errdefer test_alloc.destroy(buffer_writer);

        const writer = try test_alloc.create(StackWriter);
        writer.* = StackWriter.init(test_alloc, buffer_writer.any(), .{});
        errdefer {
            writer.deinit();
            test_alloc.destroy(writer);
        }

        const script = try test_alloc.create(Script);
        errdefer test_alloc.destroy(script);
        script.* = try Script.init(writer, null);
        errdefer script.deinit();

        const imp_std = try script.import("std");
        assert(std.mem.eql(u8, imp_std.name, "_imp_std"));

        return .{
            .arena = arena,
            .buffer = buffer,
            .buffer_writer = buffer_writer,
            .writer = writer,
            .script = script,
        };
    }

    pub fn deinit(self: *ScriptTester) void {
        if (!self.did_end) self.script.deinit();
        test_alloc.destroy(self.script);
        test_alloc.destroy(self.writer);

        test_alloc.destroy(self.buffer_writer);

        self.buffer.deinit();
        test_alloc.destroy(self.buffer);

        self.arena.deinit();
        test_alloc.destroy(self.arena);
    }

    pub fn expect(self: *ScriptTester, comptime expected: []const u8) !void {
        self.did_end = true;
        try self.script.end();
        try testing.expectEqualStrings(
            expected ++ "\n\nconst _imp_std = @import(\"std\");",
            self.buffer.items,
        );
    }
};
