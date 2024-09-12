const std = @import("std");
const Allocator = std.mem.Allocator;
const test_alloc = std.testing.allocator;
const jobz = @import("jobz");
const zig = @import("razdaz").zig;
const shape = @import("shape.zig");
const srvc = @import("service.zig");
const oper = @import("operation.zig");
const syb = @import("../systems/symbols.zig");
const SmithyId = syb.SmithyId;
const SymbolsProvider = syb.SymbolsProvider;
const IssuesBag = @import("../systems/issues.zig").IssuesBag;
const name_util = @import("../utils/names.zig");
const test_symbols = @import("../testing/symbols.zig");

pub const ResourceShapeHeadHook = jobz.Task.Hook(
    "Smithy Resource Shape Head",
    anyerror!void,
    &.{ *zig.ContainerBuild, SmithyId, *const syb.SmithyResource },
);

pub fn resourceFilename(allocator: Allocator, symbols: *SymbolsProvider, id: SmithyId) ![]const u8 {
    const shape_name = try symbols.getShapeNameRaw(id);
    return try std.fmt.allocPrint(allocator, "resource_{s}.zig", .{name_util.SnakeCase{ .value = shape_name }});
}

pub const ClientResource = srvc.ScriptCodegen.Task("Smithy Client Resource Codegen", clientResourceTask, .{
    .injects = &.{SymbolsProvider},
});
fn clientResourceTask(self: *const jobz.Delegate, symbols: *SymbolsProvider, bld: *zig.ContainerBuild, rid: SmithyId) anyerror!void {
    try bld.constant("srvc_errors").assign(bld.x.import("errors.zig"));

    try self.evaluate(WriteResource, .{ bld, rid });
    while (symbols.next()) |id| {
        try self.evaluate(shape.WriteShape, .{ bld, id });
    }
}

test ClientResource {
    var tester = try jobz.PipelineTester.init(.{ .invoker = shape.TEST_INVOKER });
    defer tester.deinit();

    var issues = IssuesBag.init(test_alloc);
    defer issues.deinit();
    _ = try tester.provideService(&issues, null);

    var symbols = try test_symbols.setup(tester.alloc(), &.{.service});
    defer symbols.deinit();
    _ = try tester.provideService(&symbols, null);

    try srvc.expectServiceScript(
        \\const srvc_errors = @import("errors.zig");
        \\
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
    , ClientResource, tester.pipeline, .{SmithyId.of("test.serve#Resource")});
}

const WriteResource = jobz.Task.Define("Smithy Write Resource Shape", writeResourceShape, .{
    .injects = &.{ SymbolsProvider, IssuesBag },
});
fn writeResourceShape(self: *const jobz.Delegate, symbols: *SymbolsProvider, issues: *IssuesBag, bld: *zig.ContainerBuild, id: SmithyId) anyerror!void {
    const resource = if (try shape.getShapeSafe(self, symbols, issues, id)) |r| r.resource else {
        return error.MissingResourceShape;
    };

    const LIFECYCLE_OPS = &.{ "create", "put", "read", "update", "delete", "list" };
    const resource_name = symbols.getShapeName(id, .type) catch |e| {
        return shape.handleShapeWriteError(self, symbols, issues, id, e);
    };

    const context = .{ .self = self, .symbols = symbols, .id = id, .resource = resource };
    try bld.public().constant(resource_name).assign(bld.x.@"struct"().bodyWith(context, struct {
        fn f(ctx: @TypeOf(context), b: *zig.ContainerBuild) !void {
            if (ctx.self.hasOverride(ResourceShapeHeadHook)) {
                try ctx.self.evaluate(ResourceShapeHeadHook, .{ b, ctx.id, ctx.resource });
            }
            for (ctx.resource.identifiers) |d| {
                try shape.writeDocComment(ctx.self.alloc(), ctx.symbols, b, d.shape, true);
                const type_name = try ctx.symbols.getTypeName(d.shape);
                const shape_name = try name_util.snakeCase(ctx.self.alloc(), d.name);
                try b.field(shape_name).typing(b.x.raw(type_name)).end();
            }

            inline for (LIFECYCLE_OPS) |field| {
                if (@field(ctx.resource, field)) |op_id| {
                    try oper.writeOperationFunc(ctx.self, ctx.symbols, b, op_id);
                }
            }
            for (ctx.resource.operations) |op_id| try oper.writeOperationFunc(ctx.self, ctx.symbols, b, op_id);
            for (ctx.resource.collection_ops) |op_id| try oper.writeOperationFunc(ctx.self, ctx.symbols, b, op_id);
        }
    }.f));

    inline for (LIFECYCLE_OPS) |field| {
        if (@field(resource, field)) |op_id| oper.writeOperationShapes(self, symbols, bld, op_id) catch |e| {
            return shape.handleShapeWriteError(self, symbols, issues, id, e);
        };
    }

    for (resource.operations) |op_id| oper.writeOperationShapes(self, symbols, bld, op_id) catch |e| {
        return shape.handleShapeWriteError(self, symbols, issues, id, e);
    };

    for (resource.collection_ops) |op_id| oper.writeOperationShapes(self, symbols, bld, op_id) catch |e| {
        return shape.handleShapeWriteError(self, symbols, issues, id, e);
    };

    for (resource.resources) |rsc_id| symbols.enqueue(rsc_id) catch |e| {
        return shape.handleShapeWriteError(self, symbols, issues, id, e);
    };
}

test WriteResource {
    try shape.shapeTester(&.{.service}, struct {
        fn eval(tester: *jobz.PipelineTester, bld: *zig.ContainerBuild) anyerror!void {
            try tester.runTask(WriteResource, .{ bld, SmithyId.of("test.serve#Resource") });
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
