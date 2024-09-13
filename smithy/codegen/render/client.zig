const std = @import("std");
const Allocator = std.mem.Allocator;
const test_alloc = std.testing.allocator;
const jobz = @import("jobz");
const zig = @import("razdaz").zig;
const shape = @import("shape.zig");
const srvc = @import("service.zig");
const oper = @import("operation.zig");
const cfg = @import("../config.zig");
const mdl = @import("../model.zig");
const SmithyId = mdl.SmithyId;
const SmithyService = mdl.SmithyService;
const IssuesBag = @import("../systems/issues.zig").IssuesBag;
const RulesEngine = @import("../systems/rules.zig").RulesEngine;
const trt_auth = @import("../traits/auth.zig");
const trt_rules = @import("../traits/rules.zig");
const SymbolsProvider = @import("../systems/SymbolsProvider.zig");
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
};

pub const ServiceClient = srvc.ScriptCodegen.Task("Smithy Service Client Codegen", serviceClientTask, .{
    .injects = &.{SymbolsProvider},
});
fn serviceClientTask(self: *const jobz.Delegate, symbols: *SymbolsProvider, bld: *zig.ContainerBuild) anyerror!void {
    const sid = symbols.service_id;
    var testables = std.ArrayList([]const u8).init(self.alloc());

    if (symbols.hasTrait(sid, trt_rules.EndpointRuleSet.id)) {
        try testables.append("srvc_endpoint");
        try bld.constant("srvc_endpoint").assign(bld.x.import("endpoint.zig"));
    }

    try testables.append("srvc_types");
    try bld.constant("srvc_types").assign(bld.x.import("data_types.zig"));

    if (self.hasOverride(ClientScriptHeadHook)) {
        try self.evaluate(ClientScriptHeadHook, .{bld});
    }

    try self.evaluate(WriteClientStruct, .{ bld, sid });

    for (symbols.service_operations) |oid| {
        const op_snake = try symbols.getShapeName(oid, .field);
        const field_name = try std.fmt.allocPrint(self.alloc(), "op_{s}", .{op_snake});
        try testables.append(field_name);

        const filename = try oper.operationFilename(self.alloc(), symbols, oid, false);
        try bld.constant(field_name).assign(bld.x.import(filename));

        const op_shape = (try symbols.getShape(oid)).operation;
        if (op_shape.input) |tid| {
            const type_name = try symbols.getShapeName(tid, .type);
            try bld.public().constant(type_name).assign(bld.x.id(field_name).dot().id("OperationInput"));
        }

        if (op_shape.output) |tid| {
            const type_name = try symbols.getShapeName(tid, .type);
            try bld.public().constant(type_name).assign(bld.x.id(field_name).dot().id("OperationOutput"));
        }

        if (symbols.service_errors.len + op_shape.errors.len > 0) {
            const op_type = try symbols.getShapeName(oid, .type);
            const err_type = try std.fmt.allocPrint(self.alloc(), "{s}Error", .{op_type});
            try bld.public().constant(err_type).assign(bld.x.id(field_name).dot().id("OperationError"));
        }
    }

    try bld.testBlockWith(null, testables.items, struct {
        fn f(ctx: []const []const u8, b: *zig.BlockBuild) !void {
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
        \\const srvc_endpoint = @import("endpoint.zig");
        \\
        \\const srvc_types = @import("data_types.zig");
        \\
        \\/// Some _service_...
        \\pub const Client = struct {
        \\    pub fn operation(self: Client, allocator: Allocator, input: OperationInput) !smithy.Response(OperationOutput, OperationError) {
        \\        return undefined;
        \\    }
        \\};
        \\
        \\const op_operation = @import("operation/operation.zig");
        \\
        \\pub const OperationInput = op_operation.OperationInput;
        \\
        \\pub const OperationOutput = op_operation.OperationOutput;
        \\
        \\pub const OperationError = op_operation.OperationError;
        \\
        \\test {
        \\    _ = srvc_endpoint;
        \\
        \\    _ = srvc_types;
        \\
        \\    _ = op_operation;
        \\}
    , ServiceClient, tester.pipeline, .{});
}

const WriteClientStruct = jobz.Task.Define("Smithy Write Service Shape", writeClientStruct, .{
    .injects = &.{ SymbolsProvider, IssuesBag },
});
fn writeClientStruct(
    self: *const jobz.Delegate,
    symbols: *SymbolsProvider,
    issues: *IssuesBag,
    bld: *zig.ContainerBuild,
    id: SmithyId,
) anyerror!void {
    const service = if (try shape.getShapeSafe(self, symbols, issues, id)) |s| s.service else return;

    shape.writeDocComment(self.alloc(), symbols, bld, id, false) catch |e| {
        return shape.handleShapeWriteError(self, symbols, issues, id, e);
    };

    const context = .{ .self = self, .symbols = symbols, .service = service, .ops = symbols.service_operations };
    bld.public().constant(cfg.service_client_type).assign(
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
    ) catch |e| {
        return shape.handleShapeWriteError(self, symbols, issues, id, e);
    };
}

test WriteClientStruct {
    try shape.shapeTester(&.{.service_with_input_members}, struct {
        fn eval(tester: *jobz.PipelineTester, bld: *zig.ContainerBuild) anyerror!void {
            try tester.runTask(WriteClientStruct, .{ bld, SmithyId.of("test.serve#Service") });
        }
    }.eval,
        \\/// Some _service_...
        \\pub const Client = struct {
        \\    pub fn operation(self: Client, allocator: Allocator, input: OperationInput) !smithy.Response(OperationOutput, OperationError) {
        \\        return undefined;
        \\    }
        \\};
    );
}

fn writeOperationFunc(self: *const jobz.Delegate, symbols: *SymbolsProvider, bld: *zig.ContainerBuild, id: SmithyId) !void {
    const operation = (try symbols.getShape(id)).operation;
    const op_name = try symbols.getShapeName(id, .function);

    const error_type = if (operation.errors.len + symbols.service_errors.len > 0) blk: {
        const op_type = try symbols.getShapeName(id, .type);
        break :blk try std.fmt.allocPrint(self.alloc(), "{s}Error", .{op_type});
    } else null;

    const input_type: ?[]const u8 = if (operation.input) |d| try shape.typeName(symbols, d, false) else null;
    const output_type: ?[]const u8 = if (operation.output) |d| try shape.typeName(symbols, d, false) else null;
    const return_type = if (error_type) |errors|
        try std.fmt.allocPrint(self.alloc(), "!smithy.Response({s}, {s})", .{
            output_type orelse "void",
            errors,
        })
    else if (output_type) |s|
        try std.fmt.allocPrint(self.alloc(), "!{s}", .{s})
    else
        "!void";

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
    };

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

test writeOperationFunc {
    const OpFuncTest = jobz.Task.Define("Operation Function Test", struct {
        fn eval(self: *const jobz.Delegate, symbols: *SymbolsProvider, bld: *zig.ContainerBuild) anyerror!void {
            try writeOperationFunc(self, symbols, bld, SmithyId.of("test.serve#Operation"));
        }
    }.eval, .{
        .injects = &.{SymbolsProvider},
    });

    try shape.shapeTester(&.{.service}, struct {
        fn eval(tester: *jobz.PipelineTester, bld: *zig.ContainerBuild) anyerror!void {
            try tester.runTask(OpFuncTest, .{bld});
        }
    }.eval,
        \\pub fn operation(self: Client, allocator: Allocator, input: OperationInput) !smithy.Response(OperationOutput, OperationError) {
        \\    return undefined;
        \\}
    );
}

pub const ClientDataTypes = srvc.ScriptCodegen.Task("Smithy Client Data Types Codegen", clientDataTypesTask, .{
    .injects = &.{SymbolsProvider},
});
fn clientDataTypesTask(self: *const jobz.Delegate, symbols: *SymbolsProvider, bld: *zig.ContainerBuild) anyerror!void {
    for (symbols.service_data_shapes) |id| {
        try self.evaluate(shape.WriteShape, .{ bld, id });
    }
}
