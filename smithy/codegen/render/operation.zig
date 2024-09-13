const std = @import("std");
const Allocator = std.mem.Allocator;
const test_alloc = std.testing.allocator;
const jobz = @import("jobz");
const zig = @import("razdaz").zig;
const files_jobs = @import("razdaz/jobs").files;
const shape = @import("shape.zig");
const srvc = @import("service.zig");
const cfg = @import("../config.zig");
const SmithyId = @import("../model.zig").SmithyId;
const IssuesBag = @import("../systems/issues.zig").IssuesBag;
const SymbolsProvider = @import("../systems/SymbolsProvider.zig");
const name_util = @import("../utils/names.zig");
const trt_http = @import("../traits/http.zig");
const trt_refine = @import("../traits/refine.zig");
const trt_behave = @import("../traits/behavior.zig");
const AuthId = @import("../traits/auth.zig").AuthId;
const test_symbols = @import("../testing/symbols.zig");

pub const OperationScriptHeadHook = jobz.Task.Hook(
    "Smithy Operation Script Head",
    anyerror!void,
    &.{ *zig.ContainerBuild, SmithyId },
);

pub fn operationFilename(allocator: Allocator, symbols: *SymbolsProvider, id: SmithyId, comptime nested: bool) ![]const u8 {
    const shape_name = try symbols.getShapeName(id, .field);
    const template = comptime if (nested) "{s}.zig" else "operation/{s}.zig";
    return try std.fmt.allocPrint(allocator, template, .{shape_name});
}

pub const ClientOperationsDir = files_jobs.OpenDir.Task("Smithy Codegen Client Operations Directory", clientOperationsDirTask, .{
    .injects = &.{SymbolsProvider},
});
fn clientOperationsDirTask(self: *const jobz.Delegate, symbols: *SymbolsProvider) anyerror!void {
    for (symbols.service_operations) |oid| {
        const filename = try operationFilename(self.alloc(), symbols, oid, true);
        try self.evaluate(files_jobs.WriteFile.Chain(ClientOperation, .sync), .{ filename, .{}, oid });
    }
}

const ClientOperation = srvc.ScriptCodegen.Task("Smithy Codegen Client Operation", clientOperationTask, .{
    .injects = &.{SymbolsProvider},
});
fn clientOperationTask(self: *const jobz.Delegate, symbols: *SymbolsProvider, bld: *zig.ContainerBuild, id: SmithyId) anyerror!void {
    const operation = (try symbols.getShape(id)).operation;

    if (symbols.service_operations.len > 0) {
        try bld.constant("srvc_types").assign(bld.x.import("data_types.zig"));
    }

    if (self.hasOverride(OperationScriptHeadHook)) {
        try self.evaluate(OperationScriptHeadHook, .{ bld, id });
    }

    if (operation.input) |in_id| {
        const members = (try symbols.getShape(in_id)).structure;
        try shape.writeStructShape(self, symbols, bld, in_id, members, "OperationInput");
    }

    if (operation.output) |out_id| {
        const members = (try symbols.getShape(out_id)).structure;
        try shape.writeStructShape(self, symbols, bld, out_id, members, "OperationOutput");
    }

    if (symbols.service_errors.len + operation.errors.len > 0) {
        try bld.public().constant("OperationError").assign(bld.x.@"enum"().bodyWith(ErrorSetCtx{
            .arena = self.alloc(),
            .symbols = symbols,
            .shape_errors = operation.errors,
            .common_errors = symbols.service_errors,
        }, writeErrorSet));
    }
}

const ErrorSetCtx = struct {
    arena: Allocator,
    symbols: *SymbolsProvider,
    common_errors: []const SmithyId,
    shape_errors: []const SmithyId,
};

const ErrorSetMember = struct {
    name: []const u8,
    code: u10,
    retryable: bool,
    source: trt_refine.Error.Source,
};

fn writeErrorSet(ctx: ErrorSetCtx, bld: *zig.ContainerBuild) !void {
    var members = std.ArrayList(ErrorSetMember).init(ctx.arena);
    defer members.deinit();

    for (ctx.common_errors) |m| try writeErrorSetMember(ctx.arena, ctx.symbols, bld, &members, m);
    for (ctx.shape_errors) |m| try writeErrorSetMember(ctx.arena, ctx.symbols, bld, &members, m);

    try bld.public().function("source")
        .arg("self", bld.x.This())
        .returns(bld.x.raw("smithy.ErrorSource"))
        .bodyWith(members.items, writeErrorSetSourceFn);

    try bld.public().function("httpStatus")
        .arg("self", bld.x.This())
        .returns(bld.x.raw("std.http.Status"))
        .bodyWith(members.items, writeErrorSetStatusFn);

    try bld.public().function("retryable")
        .arg("self", bld.x.This())
        .returns(bld.x.typeOf(bool))
        .bodyWith(members.items, writeErrorSetRetryFn);
}

fn writeErrorSetMember(
    arena: Allocator,
    symbols: *SymbolsProvider,
    bld: *zig.ContainerBuild,
    list: *std.ArrayList(ErrorSetMember),
    member: SmithyId,
) !void {
    var shape_name = try symbols.getShapeName(member, .field);
    inline for (.{ "_error", "_exception" }) |suffix| {
        if (std.ascii.endsWithIgnoreCase(shape_name, suffix)) {
            shape_name = shape_name[0 .. shape_name.len - suffix.len];
            break;
        }
    }

    try shape.writeDocComment(arena, symbols, bld, member, true);
    try bld.field(shape_name).end();

    const source = trt_refine.Error.get(symbols, member) orelse return error.MissingErrorTrait;
    try list.append(.{
        .name = shape_name,
        .source = source,
        .retryable = symbols.hasTrait(member, trt_behave.retryable_id),
        .code = trt_http.HttpError.get(symbols, member) orelse if (source == .client) 400 else 500,
    });
}

fn writeErrorSetSourceFn(members: []ErrorSetMember, bld: *zig.BlockBuild) !void {
    try bld.returns().switchWith(bld.x.id("self"), members, struct {
        fn f(ms: []ErrorSetMember, b: *zig.SwitchBuild) !void {
            for (ms) |m| try b.branch().case(b.x.dot().id(m.name)).body(b.x.raw(switch (m.source) {
                .client => ".client",
                .server => ".server",
            }));
        }
    }.f).end();
}

fn writeErrorSetStatusFn(members: []ErrorSetMember, bld: *zig.BlockBuild) !void {
    try bld.constant("code").assign(bld.x.switchWith(bld.x.id("self"), members, struct {
        fn f(ms: []ErrorSetMember, b: *zig.SwitchBuild) !void {
            for (ms) |m| try b.branch().case(b.x.dot().id(m.name)).body(b.x.valueOf(m.code));
        }
    }.f));

    try bld.returns().call("@enumFromInt", &.{bld.x.id("code")}).end();
}

fn writeErrorSetRetryFn(members: []ErrorSetMember, bld: *zig.BlockBuild) !void {
    try bld.returns().switchWith(bld.x.id("self"), members, struct {
        fn f(ms: []ErrorSetMember, b: *zig.SwitchBuild) !void {
            for (ms) |m| try b.branch().case(b.x.dot().id(m.name)).body(b.x.valueOf(m.retryable));
        }
    }.f).end();
}

test ClientOperation {
    var tester = try jobz.PipelineTester.init(.{});
    defer tester.deinit();

    var issues = IssuesBag.init(test_alloc);
    defer issues.deinit();
    _ = try tester.provideService(&issues, null);

    var symbols = try test_symbols.setup(tester.alloc(), &.{ .service, .err });
    defer symbols.deinit();
    _ = try tester.provideService(&symbols, null);

    symbols.service_id = SmithyId.of("test.serve#Service");
    try srvc.expectServiceScript(
        \\const srvc_types = @import("data_types.zig");
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
        \\pub const OperationError = enum {
        \\    service,
        \\    not_found,
        \\
        \\    pub fn source(self: @This()) smithy.ErrorSource {
        \\        return switch (self) {
        \\            .service => .client,
        \\            .not_found => .server,
        \\        };
        \\    }
        \\
        \\    pub fn httpStatus(self: @This()) std.http.Status {
        \\        const code = switch (self) {
        \\            .service => 429,
        \\            .not_found => 500,
        \\        };
        \\
        \\        return @enumFromInt(code);
        \\    }
        \\
        \\    pub fn retryable(self: @This()) bool {
        \\        return switch (self) {
        \\            .service => true,
        \\            .not_found => false,
        \\        };
        \\    }
        \\};
    , ClientOperation, tester.pipeline, .{SmithyId.of("test.serve#Operation")});
}
