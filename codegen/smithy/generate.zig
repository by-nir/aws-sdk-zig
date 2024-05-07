//! Produces Zig source code from a Smithy model.
//!
//! The following codebase is generated for a Smithy model:
//! - `<service_name>/`
//!   - `README.md`
//!   - `root.zig`
const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const test_model = @import("tests/model.zig");
const syb_id = @import("symbols/identity.zig");
const SmithyId = syb_id.SmithyId;
const SmithyType = syb_id.SmithyType;
const SmithyModel = @import("symbols/shapes.zig").SmithyModel;
const Script = @import("generate/Zig.zig");
const StackWriter = @import("utils/StackWriter.zig");
const trt_refine = @import("prelude/refine.zig");
const trt_constr = @import("prelude/constraint.zig");

const Self = @This();
pub const Options = struct {
};

arena: Allocator,
options: Options,
model: *const SmithyModel,

/// Must `close()` the returned directory when complete.
pub fn getModelDir(rel_base: []const u8, rel_model: []const u8) !fs.Dir {
    var raw_path: [128]u8 = undefined;
    @memcpy(raw_path[0..rel_base.len], rel_base);
    raw_path[rel_base] = '/';

    @memcpy(raw_path[rel_base.len + 1 ..][0..rel_model.len], rel_model);
    const path = raw_path[0 .. rel_base.len + 1 + rel_model.len];

    return fs.cwd().openDir(path, .{}) catch |e| switch (e) {
        error.FileNotFound => try fs.cwd().makeOpenPath(path, .{}),
        else => return e,
    };
}

pub fn generateModel(arena: Allocator, name: []const u8, model: *const SmithyModel, options: Options) !void {
    const self = Self{
        .arena = arena,
        .options = options,
        .model = model,
    };
    _ = self;
    _ = name;
}

/// Optionaly add any (or none) of the ReadmeSlots to the template. Each specifier
/// may appear more then once or not at all.
fn writeReadme(arena: Allocator, comptime template: []const u8, slots: ReadmeSlots) ![]const u8 {
    return std.fmt.allocPrint(arena, template, slots);
}

test "writeReadme" {
    const template = @embedFile("tests/README.md.template");
    const slots = ReadmeSlots{ .title = "Foo Bar", .slug = "foo-bar" };
    const output = try writeReadme(test_alloc, template, slots);
    defer test_alloc.free(output);
    try testing.expectEqualStrings(
        \\# Generated Foo Bar Service
        \\Learn more – [user guide](https://example.com/foo-bar)
    , output);
}

fn writeScriptShape(self: Self, script: *Script, id: SmithyId) !void {
    switch (try self.model.tryGetShape(id)) {
        .list => |m| try self.writeListShape(script, id, m),
        .map => |m| try self.writeMapShape(script, id, m),
        .str_enum => |m| try self.writeStrEnumShape(script, id, m),
        .int_enum => |m| try self.writeIntEnumShape(script, id, m),
        .tagged_uinon => |m| try self.writeUnionShape(script, id, m),
        .structure => |m| try self.writeStructShape(script, id, m),
        // TODO: service/operation/resource
        .string => {
            if (trt_constr.Enum.get(self.model, id)) |members| {
                return self.writeTraitEnumShape(script, id, members);
            } else {
                return error.InvalidRootShape;
            }
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

    const self = Self{
        .arena = tester.arena.allocator(),
        .options = .{},
        .model = &model,
    };
    try testing.expectError(
        error.InvalidRootShape,
        self.writeScriptShape(tester.script, SmithyId.of("test#Unit")),
    );
    try tester.expect("");
}

fn writeListShape(self: Self, script: *Script, id: SmithyId, memeber: SmithyId) !void {
    const shape_name = try self.model.tryGetName(id);
    const target_type = Script.TypeExpr{ .raw = try self.getShapeName(memeber) };
    if (self.model.hasTrait(id, trt_constr.unique_items_id)) {
        const target = Script.TypeExpr{
            .expr = &Script.Expr.call(
                "*const _imp_std.AutoArrayHashMapUnmanaged",
                &.{ .{ .type = target_type }, .{ .raw = "void" } },
            ),
        };
        _ = try script.variable(
            .{ .is_public = true },
            .{ .identifier = .{ .name = shape_name } },
            .{ .type = target },
        );
    } else {
        const target = if (self.model.hasTrait(id, trt_refine.sparse_id))
            Script.TypeExpr{ .optional = &target_type }
        else
            target_type;
        _ = try script.variable(
            .{ .is_public = true },
            .{ .identifier = .{ .name = shape_name } },
            .{
                .type = .{ .slice = .{ .type = &target } },
            },
        );
    }
}

test "writeListShape" {
    var tester = try ScriptTester.init();
    defer tester.deinit();

    var model = SmithyModel{};
    try test_model.setupList(&model);
    defer model.deinit(test_alloc);

    const self = Self{
        .arena = tester.arena.allocator(),
        .options = .{},
        .model = &model,
    };

    try self.writeScriptShape(tester.script, SmithyId.of("test#List"));
    try self.writeScriptShape(tester.script, SmithyId.of("test#Set"));
    try tester.expect(
        \\pub const List = []const ?i32;
        \\pub const Set = *const _imp_std.AutoArrayHashMapUnmanaged(i32, void);
    );
}

fn writeMapShape(self: Self, script: *Script, id: SmithyId, memeber: [2]SmithyId) !void {
    const shape_name = try self.model.tryGetName(id);
    const key_name = try self.getShapeName(memeber[0]);
    const val_type = try self.getShapeName(memeber[1]);
    const value: Script.Expr = if (self.model.hasTrait(id, trt_refine.sparse_id))
        .{ .raw_seq = &.{ "?", val_type } }
    else
        .{ .raw = val_type };

    _ = try script.variable(
        .{ .is_public = true },
        .{ .identifier = .{ .name = shape_name } },
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

    const self = Self{
        .arena = tester.arena.allocator(),
        .options = .{},
        .model = &model,
    };

    try self.writeScriptShape(tester.script, SmithyId.of("test#Map"));
    try tester.expect("pub const Map = *const _imp_std.AutoArrayHashMapUnmanaged(i32, ?i32);");
}

fn writeStrEnumShape(self: Self, script: *Script, id: SmithyId, members: []const SmithyId) !void {
    var list = try std.ArrayList(StrEnumMember).initCapacity(self.arena, members.len);
    defer list.deinit();
    for (members) |m| {
        const name = try self.model.tryGetName(m);
        const value = trt_refine.EnumValue.get(self.model, m);
        list.appendAssumeCapacity(.{
            .value = if (value) |v| v.string else name,
            .field = try zigifyFieldName(self.arena, name),
        });
    }
    try self.writeEnumShape(script, id, list.items);
}

fn writeTraitEnumShape(self: Self, script: *Script, id: SmithyId, members: []const trt_constr.Enum.Member) !void {
    var list = try std.ArrayList(StrEnumMember).initCapacity(self.arena, members.len);
    defer list.deinit();
    for (members) |m| {
        list.appendAssumeCapacity(.{
            .value = m.value,
            .field = try zigifyFieldName(self.arena, m.name orelse m.value),
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

fn writeEnumShape(self: Self, script: *Script, id: SmithyId, members: []const StrEnumMember) !void {
    const shape_name = try self.model.tryGetName(id);
    var scope = try script.declare(.{ .name = shape_name }, .{
        .is_public = true,
        .type = .{ .TaggedUnion = null },
    });

    var doc = try scope.comment(.doc);
    try doc.paragraph("Used for backwards compatibility when adding new values.");
    try doc.end();
    _ = try scope.field(.{ .name = "UNKNOWN", .type = .string });

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
            .{ .identifier = .{ .name = "value" }, .type = .string },
        },
        .return_type = .This,
    });
    try blk.prefix(.ret).exprFmt("{}.get(value) orelse .{{ .UNKNOWN = value }}", .{map_values});
    try blk.end();

    blk = try scope.function(.{
        .is_public = true,
    }, .{
        .identifier = .{ .name = "serialize" },
        .parameters = &.{Script.param_self},
        .return_type = .string,
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

    const self = Self{
        .arena = tester.arena.allocator(),
        .options = .{},
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

fn writeIntEnumShape(self: Self, script: *Script, id: SmithyId, members: []const SmithyId) !void {
    const shape_name = try self.model.tryGetName(id);
    var scope = try script.declare(.{ .name = shape_name }, .{
        .is_public = true,
        .type = .{ .Enum = .{ .raw = "i32" } },
    });

    for (members) |m| {
        _ = try scope.field(.{
            .name = try zigifyFieldName(self.arena, try self.model.tryGetName(m)),
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
            .{ .identifier = .{ .name = "value" }, .type = Script.TypeExpr.of(i32) },
        },
        .return_type = .This,
    });
    try blk.prefix(.ret).expr(.{ .raw = "@enumFromInt(value)" });
    try blk.end();

    blk = try scope.function(.{
        .is_public = true,
    }, .{
        .identifier = .{ .name = "serialize" },
        .parameters = &.{Script.param_self},
        .return_type = Script.TypeExpr.of(i32),
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

    const self = Self{
        .arena = tester.arena.allocator(),
        .options = .{},
        .model = &model,
    };

    try self.writeScriptShape(tester.script, SmithyId.of("test#IntEnum"));
    try tester.expect(
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

fn writeUnionShape(self: Self, script: *Script, id: SmithyId, members: []const SmithyId) !void {
    const shape_name = try self.model.tryGetName(id);
    var scope = try script.declare(.{ .name = shape_name }, .{
        .is_public = true,
        .type = .{ .TaggedUnion = null },
    });
    for (members) |m| {
        const shape = try self.getShapeName(m);
        _ = try scope.field(.{
            .name = try zigifyFieldName(self.arena, try self.model.tryGetName(m)),
            .type = if (shape.len > 0) .{ .raw = shape } else null,
        });
    }
    try scope.end();
}

test "writeUnionShape" {
    var tester = try ScriptTester.init();
    defer tester.deinit();

    var model = SmithyModel{};
    try test_model.setupUnion(&model);
    defer model.deinit(test_alloc);

    const self = Self{
        .arena = tester.arena.allocator(),
        .options = .{},
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

fn writeStructShape(self: Self, script: *Script, id: SmithyId, members: []const SmithyId) !void {
    const shape_name = try self.model.tryGetName(id);
    const is_input = self.model.hasTrait(id, trt_refine.input_id);
    var scope = try script.declare(.{ .name = shape_name }, .{
        .is_public = true,
        .type = .{ .Struct = null },
    });
    try self.writeStructShapeMixin(&scope, is_input, id);
    for (members) |m| {
        try self.writeStructShapeMember(&scope, is_input, m);
    }
    try scope.end();
}

fn writeStructShapeMixin(self: Self, script: *Script, is_input: bool, id: SmithyId) !void {
    const mixins = self.model.getMixins(id) orelse return;
    for (mixins) |mix_id| {
        try self.writeStructShapeMixin(script, is_input, mix_id);
        const mixin = (try self.model.tryGetShape(mix_id)).structure;
        for (mixin) |m| {
            try self.writeStructShapeMember(script, is_input, m);
        }
    }
}

fn writeStructShapeMember(self: Self, script: *Script, is_input: bool, id: SmithyId) !void {
    // https://smithy.io/2.0/spec/aggregate-types.html#structure-member-optionality
    const optional = if (is_input) true else if (self.model.getTraits(id)) |bag| blk: {
        break :blk bag.has(trt_refine.client_optional_id) or
            !(bag.has(trt_refine.required_id) or bag.has(trt_refine.Default.id));
    } else true;
    const assign: ?Script.Expr = blk: {
        break :blk if (optional)
            .{ .raw = "null" }
        else if (trt_refine.Default.get(self.model, id)) |t|
            switch (try self.unwrapShapeType(id)) {
                .str_enum => Script.Expr{ .val_enum = t.string },
                .int_enum => Script.Expr.call("@enumFromInt", &.{Script.Expr.val(t.integer)}),
                else => .{ .json = t },
            }
        else
            null;
    };
    const type_expr = Script.TypeExpr{ .raw = try self.getShapeName(id) };
    _ = try script.field(.{
        .name = try zigifyFieldName(self.arena, try self.model.tryGetName(id)),
        .type = if (optional) .{ .optional = &type_expr } else type_expr,
        .assign = assign,
    });
}

test "writeStructShape" {
    var tester = try ScriptTester.init();
    defer tester.deinit();

    var model = SmithyModel{};
    try test_model.setupStruct(&model);
    defer model.deinit(test_alloc);

    const self = Self{
        .arena = tester.arena.allocator(),
        .options = .{},
        .model = &model,
    };

    try self.writeScriptShape(tester.script, SmithyId.of("test#Struct"));
    try tester.expect(
        \\pub const Struct = struct {
        \\    mixed: ?bool = null,
        \\    foo_bar: i32,
        \\    baz_qux: IntEnum = @enumFromInt(8),
        \\};
    );
}

fn getShapeName(self: Self, id: SmithyId) ![]const u8 {
    const shape = switch (id) {
        // zig fmt: off
        inline .unit, .blob, .boolean, .string, .byte, .short, .integer, .long,
        .float, .double, .big_integer, .big_decimal, .timestamp, .document =>
            |t| std.enums.nameCast(SmithyType, t),
        // zig fmt: on
        else => try self.model.tryGetShape(id),
    };
    return switch (shape) {
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
        .target => |t| self.model.tryGetName(t),
        else => unreachable,
    };
}

fn unwrapShapeType(self: Self, id: SmithyId) !SmithyType {
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

pub const ReadmeSlots = struct {
    /// `{[title]s}` service title
    title: []const u8,
    /// `{[slug]s}` service SDK ID
    slug: []const u8,
};

fn zigifyFieldName(arena: Allocator, input: []const u8) ![]const u8 {
    var retain = true;
    for (input) |c| {
        if (std.ascii.isUpper(c)) retain = false;
    }
    if (retain) return input;

    var buffer = try std.ArrayList(u8).initCapacity(arena, input.len);
    errdefer buffer.deinit();

    var prev_upper = false;
    for (input, 0..) |c, i| {
        const is_upper = std.ascii.isUpper(c);
        try buffer.append(if (is_upper) blk: {
            if (!prev_upper and i > 0 and input[i - 1] != '_') {
                try buffer.append('_');
            }
            break :blk std.ascii.toLower(c);
        } else c);
        prev_upper = is_upper;
    }

    return try buffer.toOwnedSlice();
}

test "zigifyFieldName" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    try testing.expectEqualStrings(
        "foo_bar",
        try zigifyFieldName(arena.allocator(), "foo_bar"),
    );
    try testing.expectEqualStrings(
        "foo_bar",
        try zigifyFieldName(arena.allocator(), "fooBar"),
    );
    try testing.expectEqualStrings(
        "foo_bar",
        try zigifyFieldName(arena.allocator(), "FooBar"),
    );
    try testing.expectEqualStrings(
        "foo_bar",
        try zigifyFieldName(arena.allocator(), "FOO_BAR"),
    );
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
        std.debug.assert(std.mem.eql(u8, imp_std.name, "_imp_std"));

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
