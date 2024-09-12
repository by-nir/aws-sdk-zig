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
const test_symbols = @import("../testing/symbols.zig");

pub const ClientErrors = srvc.ScriptCodegen.Task("Smithy Client Errors Codegen", clientErrorsTask, .{
    .injects = &.{SymbolsProvider},
});
fn clientErrorsTask(self: *const jobz.Delegate, symbols: *SymbolsProvider, bld: *zig.ContainerBuild) anyerror!void {
    const service = (try symbols.getShape(symbols.service_id)).service;

    for (service.operations) |op_id| {
        try processOperationErrors(self, symbols, bld, op_id, service.errors);
    }

    for (service.resources) |rsc_id| {
        try processResourceErrors(self, symbols, bld, rsc_id, service.errors);
    }
}

fn processResourceErrors(
    self: *const jobz.Delegate,
    symbols: *SymbolsProvider,
    bld: *zig.ContainerBuild,
    rsc_id: SmithyId,
    common_errors: []const SmithyId,
) !void {
    const resource = (try symbols.getShape(rsc_id)).resource;

    for (resource.operations) |op_id| {
        try processOperationErrors(self, symbols, bld, op_id, common_errors);
    }

    for (resource.collection_ops) |op_id| {
        try processOperationErrors(self, symbols, bld, op_id, common_errors);
    }

    for (resource.resources) |sub_id| {
        try processResourceErrors(self, symbols, bld, sub_id, common_errors);
    }
}

fn processOperationErrors(
    self: *const jobz.Delegate,
    symbols: *SymbolsProvider,
    bld: *zig.ContainerBuild,
    op_id: SmithyId,
    common_errors: []const SmithyId,
) !void {
    const operation = (try symbols.getShape(op_id)).operation;
    try self.evaluate(oper.WriteErrorSet, .{ bld, op_id, operation.errors, common_errors });
}

test ClientErrors {
    var tester = try jobz.PipelineTester.init(.{ .invoker = shape.TEST_INVOKER });
    defer tester.deinit();

    var issues = IssuesBag.init(test_alloc);
    defer issues.deinit();
    _ = try tester.provideService(&issues, null);

    var symbols = try test_symbols.setup(tester.alloc(), &.{ .service, .err });
    defer symbols.deinit();
    _ = try tester.provideService(&symbols, null);

    symbols.service_id = SmithyId.of("test.serve#Service");

    const expected = oper.TEST_OPERATION_ERR ++ "\n\n" ++ oper.TEST_OPERATION_ERR;
    try srvc.expectServiceScript(expected, ClientErrors, tester.pipeline, .{});
}
