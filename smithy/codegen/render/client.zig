const std = @import("std");
const Allocator = std.mem.Allocator;
const test_alloc = std.testing.allocator;
const jobz = @import("jobz");
const zig = @import("codmod").zig;
const shape = @import("shape.zig");
const srvc = @import("service.zig");
const oper = @import("client_operation.zig");
const cfg = @import("../config.zig");
const mdl = @import("../model.zig");
const SmithyId = mdl.SmithyId;
const SmithyService = mdl.SmithyService;
const trt_rules = @import("../traits/rules.zig");
const IssuesBag = @import("../systems/issues.zig").IssuesBag;
const RulesEngine = @import("../systems/rules.zig").RulesEngine;
const SymbolsProvider = @import("../systems/SymbolsProvider.zig");
const test_symbols = @import("../testing/symbols.zig");

pub const ClientScriptHeadHook = jobz.Task.Hook("Smithy Client Script Head", anyerror!void, &.{*zig.ContainerBuild});
pub const ClientShapeHeadHook = jobz.Task.Hook("Smithy Client Shape Head", anyerror!void, &.{ *zig.ContainerBuild, *const SmithyService });
pub const ClientSendSyncFuncHook = jobz.Task.Hook("Smithy Client Send Sync Func", anyerror!void, &.{*zig.BlockBuild});

pub const ServiceClient = srvc.ScriptCodegen.Task("Smithy Service Client Codegen", serviceClientTask, .{
    .injects = &.{SymbolsProvider},
});
fn serviceClientTask(self: *const jobz.Delegate, symbols: *SymbolsProvider, bld: *zig.ContainerBuild) anyerror!void {
    const sid = symbols.service_id;
    var testables = std.ArrayList(zig.ExprBuild).init(self.alloc());

    if (symbols.hasTrait(sid, trt_rules.EndpointRuleSet.id)) {
        try testables.append(bld.x.raw(cfg.endpoint_scope));
        try bld.constant(cfg.endpoint_scope).assign(bld.x.import(cfg.endpoint_filename));
    }

    if (self.hasOverride(ClientScriptHeadHook)) {
        try self.evaluate(ClientScriptHeadHook, .{bld});
    }

    try self.evaluate(WriteClientStruct, .{ bld, sid });

    if (symbols.service_data_shapes.len > 0) {
        const imports = bld.x.import(cfg.types_filename);
        try bld.public().using(imports);
        try testables.append(imports);
    }

    for (symbols.service_operations) |oid| {
        const imports = bld.x.import(try oper.operationFilename(symbols, oid, false));
        try testables.append(imports);

        const type_name = try symbols.getShapeName(oid, .pascal, .{});
        try bld.public().constant(type_name).assign(imports.dot().id(type_name));
    }

    try bld.testBlockWith(null, testables.items, struct {
        fn f(ctx: []const zig.ExprBuild, b: *zig.BlockBuild) !void {
            for (ctx) |testable| try b.discard().buildExpr(testable).end();
        }
    }.f);
}

const WriteClientStruct = jobz.Task.Define("Smithy Write Service Shape", writeClientStruct, .{
    .injects = &.{SymbolsProvider},
});
fn writeClientStruct(
    self: *const jobz.Delegate,
    symbols: *SymbolsProvider,
    bld: *zig.ContainerBuild,
    id: SmithyId,
) anyerror!void {
    try shape.writeDocComment(symbols, bld, id, false);

    const service = (try symbols.getShape(id)).service;
    const context = .{ .self = self, .symbols = symbols, .service = service, .ops = symbols.service_operations };
    try bld.public().constant(cfg.service_client_type).assign(
        bld.x.@"struct"().bodyWith(context, struct {
            fn f(ctx: @TypeOf(context), b: *zig.ContainerBuild) !void {
                if (ctx.self.hasOverride(ClientShapeHeadHook)) {
                    try ctx.self.evaluate(ClientShapeHeadHook, .{ b, ctx.service });
                }

                for (ctx.ops) |op_id| try writeOperationFunc(ctx.symbols, b, op_id);

                try b.public().function("_sendSync")
                    .arg("self", b.x.id(cfg.service_client_type))
                    .arg("allocator", b.x.id("Allocator"))
                    .arg("comptime meta", null)
                    .arg("input", b.x.raw("meta.Input"))
                    .returns(b.x.typeError(null, b.x.raw("meta.Result")))
                    .bodyWith(SendSyncContext{
                    .self = ctx.self,
                    .symbols = ctx.symbols,
                }, writeSendSyncFunc);
            }
        }.f),
    );
}

const SendSyncContext = struct {
    self: *const jobz.Delegate,
    symbols: *SymbolsProvider,
};

fn writeSendSyncFunc(ctx: SendSyncContext, bld: *zig.BlockBuild) !void {
    try ctx.self.evaluate(ClientSendSyncFuncHook, .{bld});
}

fn writeOperationFunc(symbols: *SymbolsProvider, bld: *zig.ContainerBuild, id: SmithyId) !void {
    const operation = (try symbols.getShape(id)).operation;
    const return_type = try symbols.getShapeName(id, .pascal, .{});
    const input_type = if (operation.input != null)
        try symbols.getShapeName(id, .pascal, .{ .suffix = ".Input" })
    else
        null;

    const op_name = try symbols.getShapeName(id, .camel, .{});
    const func = bld.public().function(op_name)
        .arg("self", bld.x.typePointer(false, bld.x.id(cfg.service_client_type)))
        .arg(cfg.alloc_param, bld.x.raw("Allocator"));

    if (input_type) |input| {
        try func.arg("input", bld.x.raw(input))
            .returns(bld.x.raw(return_type)).body(struct {
            fn f(b: *zig.BlockBuild) !void {
                try b.returns().structLiteral(null, &.{
                    b.x.structAssign("allocator", b.x.id("allocator")),
                    b.x.structAssign("client", b.x.id("self")),
                    b.x.structAssign("input", b.x.id("input")),
                }).end();
            }
        }.f);
    } else {
        try func.returns(bld.x.raw(return_type)).body(struct {
            fn f(b: *zig.BlockBuild) !void {
                try b.returns().structLiteral(null, &.{
                    b.x.structAssign("allocator", b.x.id("allocator")),
                    b.x.structAssign("client", b.x.id("self")),
                }).end();
            }
        }.f);
    }
}

test ServiceClient {
    var tester = try jobz.PipelineTester.init(.{ .invoker = shape.TEST_INVOKER });
    defer tester.deinit();

    var symbols = try test_symbols.setup(tester.alloc(), .service);
    defer symbols.deinit();
    _ = try tester.provideService(&symbols, null);

    var rules_engine = try RulesEngine.init(test_alloc, &.{}, &.{});
    defer rules_engine.deinit(test_alloc);
    _ = try tester.provideService(&rules_engine, null);

    symbols.service_id = SmithyId.of("test.serve#Service");
    try srvc.expectServiceScript(
        \\const srvc_endpoint = @import("endpoint.zig");
        \\
        \\/// Some _service_...
        \\pub const Client = struct {
        \\    pub fn myOperation(self: *const Client, allocator: Allocator, input: MyOperation.Input) MyOperation {
        \\        return .{
        \\            .allocator = allocator,
        \\            .client = self,
        \\            .input = input,
        \\        };
        \\    }
        \\
        \\    pub fn _sendSync(self: Client, allocator: Allocator, comptime meta: anytype, input: meta.Input) !meta.Result {
        \\        return undefined;
        \\    }
        \\};
        \\
        \\pub usingnamespace @import("data_types.zig");
        \\
        \\pub const MyOperation = @import("operation/my_operation.zig").MyOperation;
        \\
        \\test {
        \\    _ = srvc_endpoint;
        \\
        \\    _ = @import("data_types.zig");
        \\
        \\    _ = @import("operation/my_operation.zig");
        \\}
    , ServiceClient, tester.pipeline, .{});
}

pub const ClientDataTypes = srvc.ScriptCodegen.Task("Smithy Client Data Types Codegen", clientDataTypesTask, .{
    .injects = &.{SymbolsProvider},
});
fn clientDataTypesTask(self: *const jobz.Delegate, symbols: *SymbolsProvider, bld: *zig.ContainerBuild) anyerror!void {
    try bld.constant("SerialType").assign(bld.x.id(cfg.runtime_scope).dot().id("SerialType"));

    const options: shape.ShapeOptions = .{
        .scheme = .{
            .serial = .{ .timestamp_fmt = symbols.service_timestamp_fmt },
        },
    };

    for (symbols.service_data_shapes) |id| {
        try shape.writeShapeDecleration(self.alloc(), symbols, bld, id, options);
    }
}

test ClientDataTypes {
    var tester = try jobz.PipelineTester.init(.{ .invoker = shape.TEST_INVOKER });
    defer tester.deinit();

    var issues = IssuesBag.init(test_alloc);
    defer issues.deinit();
    _ = try tester.provideService(&issues, null);

    var symbols = try test_symbols.setup(tester.alloc(), .service);
    defer symbols.deinit();
    _ = try tester.provideService(&symbols, null);

    try srvc.expectServiceScript(
        \\const SerialType = smithy.SerialType;
        \\
        \\pub const Foo = struct {};
        \\
        \\pub const Foo_scheme = .{ .shape = SerialType.structure, .members = .{} };
    , ClientDataTypes, tester.pipeline, .{});
}
