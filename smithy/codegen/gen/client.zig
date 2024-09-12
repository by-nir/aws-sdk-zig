const std = @import("std");
const Allocator = std.mem.Allocator;
const test_alloc = std.testing.allocator;
const jobz = @import("jobz");
const zig = @import("razdaz").zig;
const shape = @import("shape.zig");
const srvc = @import("service.zig");
const oper = @import("operation.zig");
const resourceFilename = @import("resource.zig").resourceFilename;
const cfg = @import("../config.zig");
const syb = @import("../systems/symbols.zig");
const SmithyId = syb.SmithyId;
const SymbolsProvider = syb.SymbolsProvider;
const IssuesBag = @import("../systems/issues.zig").IssuesBag;
const RulesEngine = @import("../systems/rules.zig").RulesEngine;
const trt_rules = @import("../traits/rules.zig");
const test_symbols = @import("../testing/symbols.zig");

pub const ClientScriptHeadHook = jobz.Task.Hook("Smithy Client Script Head", anyerror!void, &.{*zig.ContainerBuild});
pub const ClientShapeHeadHook = jobz.Task.Hook("Smithy Client Shape Head", anyerror!void, &.{ *zig.ContainerBuild, *const syb.SmithyService });

pub const ServiceClient = srvc.ScriptCodegen.Task("Smithy Service Client Codegen", serviceClientTask, .{
    .injects = &.{SymbolsProvider},
});
fn serviceClientTask(self: *const jobz.Delegate, symbols: *SymbolsProvider, bld: *zig.ContainerBuild) anyerror!void {
    const sid = symbols.service_id;
    var testables = std.ArrayList([]const u8).init(self.alloc());

    try bld.constant("srvc_errors").assign(bld.x.import("errors.zig"));

    if (symbols.hasTrait(sid, trt_rules.EndpointRuleSet.id)) {
        try testables.append("srvc_endpoint");
        try bld.constant("srvc_endpoint").assign(bld.x.import("endpoint.zig"));
    }

    const service = (try symbols.getShape(sid)).service;
    for (service.resources) |id| {
        const filename = try resourceFilename(self.alloc(), symbols, id);
        const field_name = filename[0 .. filename.len - ".zig".len];
        try testables.append(field_name);
        try bld.constant(field_name).assign(bld.x.import(filename));
    }

    if (self.hasOverride(ClientScriptHeadHook)) {
        try self.evaluate(ClientScriptHeadHook, .{bld});
    }

    try self.evaluate(WriteService, .{ bld, sid });
    while (symbols.next()) |id| {
        try self.evaluate(shape.WriteShape, .{ bld, id });
    }

    try bld.testBlockWith(null, testables.items, struct {
        fn f(ctx: []const []const u8, b: *zig.BlockBuild) !void {
            try b.discard().id("srvc_errors").end();
            for (ctx) |testable| try b.discard().id(testable).end();
        }
    }.f);
}

test ServiceClient {
    var tester = try jobz.PipelineTester.init(.{ .invoker = shape.TEST_INVOKER });
    defer tester.deinit();

    var issues = IssuesBag.init(test_alloc);
    defer issues.deinit();
    _ = try tester.provideService(&issues, null);

    var symbols = try test_symbols.setup(tester.alloc(), &.{.service});
    defer symbols.deinit();
    _ = try tester.provideService(&symbols, null);

    var rules_engine = try RulesEngine.init(test_alloc, &.{}, &.{});
    defer rules_engine.deinit(test_alloc);
    _ = try tester.provideService(&rules_engine, null);

    symbols.service_id = SmithyId.of("test.serve#Service");
    try srvc.expectServiceScript(
        \\const srvc_errors = @import("errors.zig");
        \\
        \\const srvc_endpoint = @import("endpoint.zig");
        \\
        \\const resource_resource = @import("resource_resource.zig");
        \\
        \\/// Some _service_...
        \\pub const Client = struct {
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
        \\
        \\test {
        \\    _ = srvc_errors;
        \\
        \\    _ = srvc_endpoint;
        \\
        \\    _ = resource_resource;
        \\}
    , ServiceClient, tester.pipeline, .{});
}

const WriteService = jobz.Task.Define("Smithy Write Service Shape", writeServiceShape, .{
    .injects = &.{ SymbolsProvider, IssuesBag },
});
fn writeServiceShape(self: *const jobz.Delegate, symbols: *SymbolsProvider, issues: *IssuesBag, bld: *zig.ContainerBuild, id: SmithyId) anyerror!void {
    const service = if (try shape.getShapeSafe(self, symbols, issues, id)) |s| s.service else {
        return error.MissingServiceShape;
    };

    shape.writeDocComment(self.alloc(), symbols, bld, id, false) catch |e| {
        return shape.handleShapeWriteError(self, symbols, issues, id, e);
    };

    const context = .{ .self = self, .symbols = symbols, .service = service };
    bld.public().constant(cfg.service_client_type).assign(
        bld.x.@"struct"().bodyWith(context, struct {
            fn f(ctx: @TypeOf(context), b: *zig.ContainerBuild) !void {
                if (ctx.self.hasOverride(ClientShapeHeadHook)) {
                    try ctx.self.evaluate(ClientShapeHeadHook, .{ b, ctx.service });
                }

                for (ctx.service.operations) |op_id| {
                    try oper.writeOperationFunc(ctx.self, ctx.symbols, b, op_id);
                }
            }
        }.f),
    ) catch |e| {
        return shape.handleShapeWriteError(self, symbols, issues, id, e);
    };

    for (service.operations) |op_id| oper.writeOperationShapes(self, symbols, bld, op_id) catch |e| {
        return shape.handleShapeWriteError(self, symbols, issues, id, e);
    };
}

test WriteService {
    try shape.shapeTester(&.{.service_with_input_members}, struct {
        fn eval(tester: *jobz.PipelineTester, bld: *zig.ContainerBuild) anyerror!void {
            try tester.runTask(WriteService, .{ bld, SmithyId.of("test.serve#Service") });
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
