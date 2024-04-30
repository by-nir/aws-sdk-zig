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
const SmithyId = @import("symbols/identity.zig").SmithyId;
const SmithyModel = @import("symbols/shapes.zig").SmithyModel;
const Script = @import("generate/Zig.zig");
const StackWriter = @import("utils/StackWriter.zig");

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

pub fn generateModel(arena: Allocator, name: []const u8, model: SmithyModel) !void {
}

fn writeScriptShape(arena: Allocator, script: *Script, model: *const SmithyModel, id: SmithyId) !void {
    switch (try model.tryGetShape(id)) {
        .@"enum" => |members| try writeEnumShape(arena, script, model, id, members),
        else => return error.InvalidRootShape,
    }
}

test "writeScriptShape" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const model = try test_model.createAggragates();
    defer test_model.deinitModel(model);

    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    var writer = StackWriter.init(test_alloc, buffer.writer().any(), .{});
    var script = try Script.init(&writer, null);

    const arena_alloc = arena.allocator();
    try testing.expectError(
        error.InvalidRootShape,
        writeScriptShape(arena_alloc, &script, model, SmithyId.of("test#Unit")),
    );
    try writeScriptShape(arena_alloc, &script, model, SmithyId.of("test#Enum"));

    try script.end();
    try testing.expectEqualStrings(TEST_ENUM, buffer.items);
}

fn writeEnumShape(
    arena: Allocator,
    script: *Script,
    model: *const SmithyModel,
    id: SmithyId,
    members: []const SmithyId,
) !void {
    const shape_name = try model.tryGetName(id);
    var scope = try script.declare(.{ .name = shape_name }, .{
        .is_public = true,
        .type = .{ .TaggedUnion = null },
    });

    var doc = try scope.comment(.doc);
    try doc.paragraph("Used for backwards compatibility when adding new values.");
    try doc.end();
    _ = try scope.field(.{ .name = "UNKNOWN", .type = .string });

    const EnumParseTuple = struct {
        str_val: []const u8,
        enum_val: Script.Identifier,

        pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.print(".{{ \"{s}\", .{} }}", .{ self.str_val, self.enum_val });
        }
    };

    var pairs = try std.ArrayList(EnumParseTuple).initCapacity(arena, members.len);
    defer pairs.deinit();
    for (members) |m| {
        const str_val = try model.tryGetName(m);
        const enm_val = try zigifyFieldName(arena, str_val);
        pairs.appendAssumeCapacity(.{ .str_val = str_val, .enum_val = .{ .name = enm_val } });
        _ = try scope.field(.{ .name = enm_val, .type = null });
    }

    const imp_std = try scope.import("std");
    const map_type = try scope.variable(.{}, .{
        .identifier = .{ .name = "ParseMap" },
    }, Script.Expr.call(
        try imp_std.child(arena, "StaticStringMap"),
        &.{.{ .raw = "@This()" }},
    ));

    const map_values = blk: {
        var vals = std.ArrayList(EnumParseTuple).init(arena);
        defer vals.deinit();

        const map_list = try scope.preRenderMultiline(arena, EnumParseTuple, pairs.items, ".{", "}");
        defer arena.free(map_list);

        break :blk try scope.variable(.{}, .{
            .identifier = .{ .name = "parse_map" },
        }, Script.Expr.call(
            try map_type.child(arena, "initComptime"),
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
        .return_type = .{ .raw = "This()" },
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
    for (pairs.items) |pair| {
        prong = try swtch.prong(&.{
            .{ .value = pair.enum_val },
        }, .{}, .inlined);
        try prong.expr(.{ .val = Script.Val.of(pair.str_val) });
        try prong.end();
    }
    try swtch.end();
    try blk.end();

    try scope.end();
}

const TEST_ENUM =
    \\pub const Enum = union(enum) {
    \\    /// Used for backwards compatibility when adding new values.
    \\    UNKNOWN: []const u8,
    \\    foo_bar,
    \\    baz_qux,
    \\
    \\    const ParseMap = _imp_std.StaticStringMap(@This());
    \\    const parse_map = ParseMap.initComptime(.{
    \\        .{ "FOO_BAR", .foo_bar },
    \\        .{ "BAZ_QUX", .baz_qux },
    \\    });
    \\
    \\    pub fn parse(value: []const u8) This() {
    \\        return parse_map.get(value) orelse .{ .UNKNOWN = value };
    \\    }
    \\
    \\    pub fn serialize(self: @This()) []const u8 {
    \\        return switch (self) {
    \\            .UNKNOWN => |s| s,
    \\            .foo_bar => "FOO_BAR",
    \\            .baz_qux => "BAZ_QUX",
    \\        }
    \\    }
    \\
    \\    const _imp_std = @import("std");
    \\};
;

pub const ReadmeSlots = struct {
    /// `{[title]s}` service title
    title: []const u8,
    /// `{[slug]s}` service SDK ID
    slug: []const u8,
};

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
