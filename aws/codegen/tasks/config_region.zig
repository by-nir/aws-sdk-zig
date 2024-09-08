const std = @import("std");
const Allocator = std.mem.Allocator;
const zig = @import("codegen").zig;
const pipez = @import("pipez");
const Delegate = pipez.Delegate;
const smithy = @import("smithy/codegen");
const codegen_tasks = smithy.codegen_tasks;
const name_util = smithy.name_util;

pub const RegionDef = struct {
    code: []const u8,
    description: ?[]const u8,
};

const Context = struct {
    arena: Allocator,
    defs: []const RegionDef,
};

pub const RegionsCodegen = codegen_tasks.ZigScript.Task("AWS Config Regions", regionsCodegenTask, .{});
fn regionsCodegenTask(self: *const Delegate, bld: *zig.ContainerBuild, defs: []const RegionDef) anyerror!void {
    try bld.constant("std").assign(bld.x.import("std"));

    const context = Context{ .arena = self.alloc(), .defs = defs };
    try bld.public().constant("Region").assign(bld.x.@"enum"().bodyWith(context, writeEnum));
}

fn writeEnum(ctx: Context, bld: *zig.ContainerBuild) !void {
    var map = try std.ArrayList(zig.ExprBuild).initCapacity(ctx.arena, ctx.defs.len);
    for (ctx.defs) |def| {
        const field = try name_util.snakeCase(ctx.arena, def.code);
        const pair = &.{ bld.x.valueOf(def.code), bld.x.dot().id(field) };
        try map.append(bld.x.structLiteral(null, pair));

        if (def.description) |doc| try bld.comment(.doc, doc);
        try bld.field(field).end();
    }

    const map_init = bld.x.raw("std.StaticStringMap(Region)").dot().call(
        "initComptime",
        &.{bld.x.structLiteral(null, try map.toOwnedSlice())},
    );
    try bld.constant("map").assign(map_init);

    try bld.public().function("parseCode")
        .arg("code", bld.x.typeOf([]const u8))
        .returns(bld.x.raw("?Region")).body(struct {
        fn f(b: *zig.BlockBuild) !void {
            try b.raw("return map.get(code)");
        }
    }.f);

    try bld.public().function("toCode")
        .arg("self", bld.x.raw("Region"))
        .returns(bld.x.typeOf([]const u8)).bodyWith(ctx, struct {
        fn f(c: Context, b: *zig.BlockBuild) !void {
            try b.returns().switchWith(b.x.id("self"), c, writeToCode).end();
        }
    }.f);
}

fn writeToCode(ctx: Context, bld: *zig.SwitchBuild) !void {
    for (ctx.defs) |def| {
        const field = try name_util.snakeCase(ctx.arena, def.code);
        try bld.branch().case(bld.x.dot().id(field)).body(bld.x.valueOf(def.code));
    }
}

test "RegionsCodegen" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    var tester = try pipez.PipelineTester.init(.{});
    defer tester.deinit();

    const output = try codegen_tasks.evaluateZigScript(arena_alloc, tester.pipeline, RegionsCodegen, .{TEST_DEFS});
    try codegen_tasks.expectEqualZigScript(TEST_OUT, output);
}

const TEST_DEFS = &[_]RegionDef{
    .{ .code = "il-central-1", .description = "Israel (Tel Aviv)" },
    .{ .code = "us-east-1", .description = "US East (N. Virginia)" },
    .{ .code = "aws-cn-global", .description = "AWS China global region" },
    .{ .code = "cn-northwest-1", .description = "China (Ningxia)" },
    .{ .code = "us-gov-west-1", .description = "AWS GovCloud (US-West)" },
};

const TEST_OUT: []const u8 =
    \\const std = @import("std");
    \\
    \\pub const Region = enum {
    \\    /// Israel (Tel Aviv)
    \\    il_central_1,
    \\    /// US East (N. Virginia)
    \\    us_east_1,
    \\    /// AWS China global region
    \\    aws_cn_global,
    \\    /// China (Ningxia)
    \\    cn_northwest_1,
    \\    /// AWS GovCloud (US-West)
    \\    us_gov_west_1,
    \\
    \\    const map = std.StaticStringMap(Region).initComptime(.{
    \\        .{ "il-central-1", .il_central_1 },
    \\        .{ "us-east-1", .us_east_1 },
    \\        .{ "aws-cn-global", .aws_cn_global },
    \\        .{ "cn-northwest-1", .cn_northwest_1 },
    \\        .{ "us-gov-west-1", .us_gov_west_1 },
    \\    });
    \\
    \\    pub fn parseCode(code: []const u8) ?Region {
    \\        return map.get(code);
    \\    }
    \\
    \\    pub fn toCode(self: Region) []const u8 {
    \\        return switch (self) {
    \\            .il_central_1 => "il-central-1",
    \\            .us_east_1 => "us-east-1",
    \\            .aws_cn_global => "aws-cn-global",
    \\            .cn_northwest_1 => "cn-northwest-1",
    \\            .us_gov_west_1 => "us-gov-west-1",
    \\        };
    \\    }
    \\};
;
