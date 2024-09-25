const std = @import("std");
const Allocator = std.mem.Allocator;
const test_alloc = std.testing.allocator;
const jobz = @import("jobz");
const zig = @import("razdaz").zig;
const shape = @import("shape.zig");
const srvc = @import("service.zig");
const oper = @import("client_operation.zig");
const cfg = @import("../config.zig");
const mdl = @import("../model.zig");
const SmithyId = mdl.SmithyId;
const SmithyService = mdl.SmithyService;
const IssuesBag = @import("../systems/issues.zig").IssuesBag;
const RulesEngine = @import("../systems/rules.zig").RulesEngine;
const SymbolsProvider = @import("../systems/SymbolsProvider.zig");
const trt_auth = @import("../traits/auth.zig");
const trt_rules = @import("../traits/rules.zig");
const test_symbols = @import("../testing/symbols.zig");

pub const ClientScriptHeadHook = jobz.Task.Hook("Smithy Client Script Head", anyerror!void, &.{*zig.ContainerBuild});
pub const ClientShapeHeadHook = jobz.Task.Hook("Smithy Client Shape Head", anyerror!void, &.{ *zig.ContainerBuild, *const SmithyService });
pub const ClientOperationFuncHook = jobz.Task.Hook("Smithy Client Operation Func", anyerror!void, &.{ *zig.BlockBuild, OperationFunc });

pub const OperationFunc = struct {
    id: SmithyId,
    input_type: ?[]const u8,
    output_type: ?[]const u8,
    errors_type: ?[]const u8,
    return_type: []const u8,
    auth_optional: bool,
    auth_schemes: []const trt_auth.AuthId,
    serial_input: ?[]const u8,
    serial_output: ?[]const u8,
    serial_error: ?[]const u8,
};

pub const ServiceClient = srvc.ScriptCodegen.Task("Smithy Service Client Codegen", serviceClientTask, .{
    .injects = &.{SymbolsProvider},
});
fn serviceClientTask(self: *const jobz.Delegate, symbols: *SymbolsProvider, bld: *zig.ContainerBuild) anyerror!void {
    const sid = symbols.service_id;
    var testables = std.ArrayList([]const u8).init(self.alloc());

    if (symbols.hasTrait(sid, trt_rules.EndpointRuleSet.id)) {
        try testables.append(cfg.endpoint_scope);
        try bld.constant(cfg.endpoint_scope).assign(bld.x.import(cfg.endpoint_filename));
    }

    if (self.hasOverride(ClientScriptHeadHook)) {
        try self.evaluate(ClientScriptHeadHook, .{bld});
    }

    try self.evaluate(WriteClientStruct, .{ bld, sid });

    if (symbols.service_data_shapes.len > 0) {
        try bld.public().using(bld.x.import(cfg.types_filename));
        try testables.append("@import(\"" ++ cfg.types_filename ++ "\")");
    }

    for (symbols.service_operations) |oid| {
        const field_name = try symbols.getShapeName(oid, .snake, .{ .suffix = "_op" });
        try testables.append(field_name);

        const filename = try oper.operationFilename(symbols, oid, false);
        try bld.constant(field_name).assign(bld.x.import(filename));

        const type_name = try symbols.getShapeName(oid, .pascal, .{});
        try bld.public().constant(type_name).assign(bld.x.id(field_name).dot().id(type_name));
    }

    try bld.testBlockWith(null, testables.items, struct {
        fn f(ctx: []const []const u8, b: *zig.BlockBuild) !void {
            for (ctx) |testable| try b.discard().raw(testable).end();
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

                for (ctx.ops) |op_id| {
                    try writeOperationFunc(ctx.self, ctx.symbols, b, op_id);
                }
            }
        }.f),
    );
}

fn writeOperationFunc(self: *const jobz.Delegate, symbols: *SymbolsProvider, bld: *zig.ContainerBuild, id: SmithyId) !void {
    const operation = (try symbols.getShape(id)).operation;

    const input_type, const input_serial = if (operation.input != null) .{
        try symbols.getShapeName(id, .pascal, .{ .suffix = ".Input" }),
        try symbols.getShapeName(id, .snake, .{ .suffix = "_op.serial_input_scheme" }),
    } else .{ null, null };

    const output_type, const output_serial = if (operation.output != null) .{
        try symbols.getShapeName(id, .pascal, .{ .suffix = ".Output" }),
        try symbols.getShapeName(id, .snake, .{ .suffix = "_op.serial_output_scheme" }),
    } else .{ null, null };

    const error_type, const error_serial = if (operation.errors.len + symbols.service_errors.len > 0) .{
        try symbols.getShapeName(id, .pascal, .{ .suffix = ".ErrorKind" }),
        try symbols.getShapeName(id, .snake, .{ .suffix = "_op.serial_error_scheme" }),
    } else .{ null, null };

    const return_type = try symbols.getShapeName(id, .pascal, .{
        .prefix = "!",
        .suffix = ".Result",
    });

    const auth_optional = symbols.hasTrait(id, trt_auth.optional_auth_id);
    const auth_schemes = trt_auth.Auth.get(symbols, id) orelse
        trt_auth.Auth.get(symbols, symbols.service_id) orelse
        symbols.service_auth_schemes;

    const op_shape = OperationFunc{
        .id = id,
        .input_type = input_type,
        .output_type = output_type,
        .errors_type = error_type,
        .return_type = return_type,
        .auth_optional = auth_optional,
        .auth_schemes = auth_schemes,
        .serial_input = input_serial,
        .serial_output = output_serial,
        .serial_error = error_serial,
    };

    const op_name = try symbols.getShapeName(id, .camel, .{});
    const context = .{ .self = self, .symbols = symbols, .shape = op_shape };
    const func1 = bld.public().function(op_name)
        .arg("self", bld.x.id(cfg.service_client_type))
        .arg(cfg.alloc_param, bld.x.raw("Allocator"));
    const func2 = if (input_type) |input| func1.arg("input", bld.x.raw(input)) else func1;
    try func2.returns(bld.x.raw(return_type)).bodyWith(context, struct {
        fn f(ctx: @TypeOf(context), b: *zig.BlockBuild) !void {
            try ctx.self.evaluate(ClientOperationFuncHook, .{ b, ctx.shape });
        }
    }.f);
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
        \\    pub fn myOperation(self: Client, allocator: Allocator, input: MyOperation.Input) !MyOperation.Result {
        \\        return undefined;
        \\    }
        \\};
        \\
        \\pub usingnamespace @import("data_types.zig");
        \\
        \\const my_operation_op = @import("operation/my_operation.zig");
        \\
        \\pub const MyOperation = my_operation_op.MyOperation;
        \\
        \\test {
        \\    _ = srvc_endpoint;
        \\
        \\    _ = @import("data_types.zig");
        \\
        \\    _ = my_operation_op;
        \\}
    , ServiceClient, tester.pipeline, .{});
}

pub const ClientDataTypes = srvc.ScriptCodegen.Task("Smithy Client Data Types Codegen", clientDataTypesTask, .{
    .injects = &.{SymbolsProvider},
});
fn clientDataTypesTask(self: *const jobz.Delegate, symbols: *SymbolsProvider, bld: *zig.ContainerBuild) anyerror!void {
    for (symbols.service_data_shapes) |id| {
        try shape.writeShapeDecleration(self.alloc(), symbols, bld, id, .{});
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

    try srvc.expectServiceScript("pub const Foo = struct {};", ClientDataTypes, tester.pipeline, .{});
}
