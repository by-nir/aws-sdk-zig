const std = @import("std");
const Allocator = std.mem.Allocator;
const test_alloc = std.testing.allocator;
const jobz = @import("jobz");
const md = @import("razdaz").md;
const zig = @import("razdaz").zig;
const files_jobs = @import("razdaz/jobs").files;
const shape = @import("shape.zig");
const srvc = @import("service.zig");
const cfg = @import("../config.zig");
const SmithyId = @import("../model.zig").SmithyId;
const IssuesBag = @import("../systems/issues.zig").IssuesBag;
const SymbolsProvider = @import("../systems/SymbolsProvider.zig");
const name_util = @import("../utils/names.zig");
const trt_refine = @import("../traits/refine.zig");
const AuthId = @import("../traits/auth.zig").AuthId;
const test_symbols = @import("../testing/symbols.zig");

pub const OperationScriptHeadHook = jobz.Task.Hook(
    "Smithy Operation Script Head",
    anyerror!void,
    &.{ *zig.ContainerBuild, SmithyId },
);

pub fn operationFilename(symbols: *SymbolsProvider, id: SmithyId, comptime nested: bool) ![]const u8 {
    return try symbols.getShapeName(id, .snake, .{
        .prefix = if (nested) "" else "operation/",
        .suffix = ".zig",
    });
}

pub const ClientOperationsDir = files_jobs.OpenDir.Task(
    "Smithy Codegen Client Operations Directory",
    clientOperationsDirTask,
    .{ .injects = &.{SymbolsProvider} },
);
fn clientOperationsDirTask(self: *const jobz.Delegate, symbols: *SymbolsProvider) anyerror!void {
    for (symbols.service_operations) |oid| {
        const filename = try operationFilename(symbols, oid, true);
        try self.evaluate(files_jobs.WriteFile.Chain(ClientOperation, .sync), .{ filename, .{}, oid });
    }
}

const ClientOperation = srvc.ScriptCodegen.Task("Smithy Codegen Client Operation", clientOperationTask, .{
    .injects = &.{ SymbolsProvider, IssuesBag },
});
fn clientOperationTask(
    self: *const jobz.Delegate,
    symbols: *SymbolsProvider,
    issues: *IssuesBag,
    bld: *zig.ContainerBuild,
    id: SmithyId,
) anyerror!void {
    try bld.constant("SerialType").assign(bld.x.id(cfg.runtime_scope).dot().id("SerialType"));

    if (symbols.service_operations.len > 0) {
        try bld.constant(cfg.types_scope).assign(bld.x.import("../" ++ cfg.types_filename));
    }

    if (self.hasOverride(OperationScriptHeadHook)) {
        try self.evaluate(OperationScriptHeadHook, .{ bld, id });
    }

    const operation = (try symbols.getShape(id)).operation;
    const errors = try listShapeErrors(self.alloc(), symbols, operation.errors);

    const context = .{ .arena = self.alloc(), .symbols = symbols, .issues = issues, .op = operation, .errors = errors };
    try bld.public().constant(try symbols.getShapeName(id, .pascal, .{})).assign(
        bld.x.@"struct"().bodyWith(context, struct {
            fn f(ctx: @TypeOf(context), b: *zig.ContainerBuild) !void {
                try b.public().constant("Result").assign(blk: {
                    const payload = if (ctx.op.output != null) b.x.id("Output") else b.x.typeOf(void);
                    if (ctx.errors.len > 0) {
                        break :blk b.x.raw(cfg.runtime_scope).dot().call("Result", &.{ payload, b.x.id("ErrorKind") });
                    } else {
                        break :blk payload;
                    }
                });

                if (ctx.op.input) |in_id| {
                    try shape.writeShapeDecleration(ctx.arena, ctx.symbols, b, in_id, .{
                        .identifier = "Input",
                        .scope = cfg.types_scope,
                    });
                }

                if (ctx.op.output) |out_id| {
                    try shape.writeShapeDecleration(ctx.arena, ctx.symbols, b, out_id, .{
                        .identifier = "Output",
                        .scope = cfg.types_scope,
                        .is_output = true,
                    });
                }

                if (ctx.errors.len > 0) {
                    try b.public().constant("Error").assign(b.x.raw(cfg.runtime_scope).dot().call("ResultError", &.{
                        b.x.id("ErrorKind"),
                    }));

                    try b.public().constant("ErrorKind").assign(b.x.@"enum"().bodyWith(ErrorSetCtx{
                        .arena = ctx.arena,
                        .symbols = ctx.symbols,
                        .members = ctx.errors,
                    }, writeErrorSet));
                }
            }
        }.f),
    );

    if (operation.input) |in_id| {
        const scheme = try serialShapeScheme(self, symbols, bld.x, in_id);
        try bld.public().constant("serial_input_scheme").assign(scheme);
    }

    if (operation.output) |out_id| {
        const scheme = try serialShapeScheme(self, symbols, bld.x, out_id);
        try bld.public().constant("serial_output_scheme").assign(scheme);
    }

    if (errors.len > 0) {
        const scheme = try serialErrorScheme(self, bld.x, errors);
        try bld.public().constant("serial_error_scheme").assign(scheme);
    }
}

fn listShapeErrors(
    arena: Allocator,
    symbols: *SymbolsProvider,
    shape_errors: []const SmithyId,
) ![]const SymbolsProvider.Error {
    if (symbols.service_errors.len + shape_errors.len == 0) return &.{};

    var members = std.ArrayList(SymbolsProvider.Error).init(arena);
    defer members.deinit();

    for (shape_errors) |eid| {
        try members.append(try symbols.buildError(eid));
    }

    try members.appendSlice(symbols.service_errors);
    return members.toOwnedSlice();
}

fn serialShapeScheme(
    self: *const jobz.Delegate,
    symbols: *SymbolsProvider,
    exp: zig.ExprBuild,
    id: SmithyId,
) !zig.ExprBuild {
    switch (try symbols.getShapeUnwrap(id)) {
        inline .boolean,
        .byte,
        .short,
        .integer,
        .long,
        .float,
        .double,
        .blob,
        .string,
        .int_enum,
        .str_enum,
        .trt_enum,
        .big_integer,
        .big_decimal,
        .timestamp,
        => |_, g| return exp.structLiteral(null, &.{exp.id("SerialType").valueOf(g)}),
        .list => |member| {
            const member_scheme = try serialShapeScheme(self, symbols, exp, member);
            return exp.structLiteral(null, switch (shape.listType(symbols, id)) {
                .standard => &.{ exp.id("SerialType").valueOf(.list), exp.valueOf(true), member_scheme },
                .sparse => &.{ exp.id("SerialType").valueOf(.list), exp.valueOf(false), member_scheme },
                .set => &.{ exp.id("SerialType").valueOf(.set), member_scheme },
            });
        },
        .map => |members| {
            const required = exp.valueOf(!symbols.hasTrait(id, trt_refine.sparse_id));
            const key_scheme = try serialShapeScheme(self, symbols, exp, members[0]);
            const val_scheme = try serialShapeScheme(self, symbols, exp, members[1]);
            return exp.structLiteral(null, &.{ exp.id("SerialType").valueOf(.map), required, key_scheme, val_scheme });
        },
        inline .structure, .tagged_union => |members, g| {
            var schemes = std.ArrayList(zig.ExprBuild).init(self.alloc());
            const is_input = symbols.hasTrait(id, trt_refine.input_id);

            for (members) |member| {
                const name_spec = exp.valueOf(try symbols.getShapeName(member, .pascal, .{}));
                const name_field = exp.valueOf(try symbols.getShapeName(member, .snake, .{}));
                const member_scheme = try serialShapeScheme(self, symbols, exp, member);
                if (g == .structure) {
                    const is_required = exp.valueOf(!shape.isStructMemberOptional(symbols, member, is_input));
                    try schemes.append(exp.structLiteral(null, &.{ name_spec, name_field, is_required, member_scheme }));
                } else {
                    try schemes.append(exp.structLiteral(null, &.{ name_spec, name_field, member_scheme }));
                }
            }

            return exp.structLiteral(null, &.{
                exp.id("SerialType").valueOf(g),
                exp.structLiteral(null, try schemes.toOwnedSlice()),
            });
        },
        .document => @panic("Document shape scheme construction not implemented"), // TODO
        .unit, .operation, .resource, .service, .target => unreachable,
    }
}

fn serialErrorScheme(
    self: *const jobz.Delegate,
    exp: zig.ExprBuild,
    members: []const SymbolsProvider.Error,
) !zig.ExprBuild {
    var scheme = std.ArrayList(zig.ExprBuild).init(self.alloc());
    for (members) |member| {
        const name_api = exp.valueOf(member.name_api);
        const name_field = exp.valueOf(member.name_field);
        try scheme.append(exp.structLiteral(null, &.{ name_api, name_field, exp.structLiteral(null, &.{}) }));
    }

    return exp.structLiteral(null, &.{
        exp.id("SerialType").valueOf(.tagged_union),
        exp.structLiteral(null, try scheme.toOwnedSlice()),
    });
}

const ErrorSetCtx = struct {
    arena: Allocator,
    symbols: *SymbolsProvider,
    members: []const SymbolsProvider.Error,
};

fn writeErrorSet(ctx: ErrorSetCtx, bld: *zig.ContainerBuild) !void {
    for (ctx.members) |member| {
        try writeErrorSetMember(ctx.arena, bld, member);
    }

    try bld.public().function("source")
        .arg("self", bld.x.This())
        .returns(bld.x.raw(cfg.runtime_scope).dot().id("ErrorSource"))
        .bodyWith(ctx.members, writeErrorSetSourceFn);

    try bld.public().function("httpStatus")
        .arg("self", bld.x.This())
        .returns(bld.x.raw("std.http.Status"))
        .bodyWith(ctx.members, writeErrorSetStatusFn);

    try bld.public().function("retryable")
        .arg("self", bld.x.This())
        .returns(bld.x.typeOf(bool))
        .bodyWith(ctx.members, writeErrorSetRetryFn);
}

fn writeErrorSetMember(arena: Allocator, bld: *zig.ContainerBuild, member: SymbolsProvider.Error) !void {
    if (member.html_docs) |docs| {
        try bld.commentMarkdownWith(.doc, md.html.CallbackContext{
            .allocator = arena,
            .html = docs,
        }, md.html.callback);
    }

    try bld.field(member.name_field).end();
}

fn writeErrorSetSourceFn(members: []const SymbolsProvider.Error, bld: *zig.BlockBuild) !void {
    var client_count: usize = 0;
    for (members) |m| {
        if (m.source == .client) client_count += 1;
    }

    if (client_count == 0) {
        try bld.discard().id("self").end();
        try bld.returns().valueOf(.server).end();
    } else if (client_count == members.len) {
        try bld.discard().id("self").end();
        try bld.returns().valueOf(.client).end();
    } else {
        const context = .{ .errs = members, .client_count = client_count };
        try bld.returns().switchWith(bld.x.id("self"), context, struct {
            fn f(ctx: @TypeOf(context), b: *zig.SwitchBuild) !void {
                const client_majority = ctx.client_count >= ctx.errs.len - ctx.client_count;
                for (ctx.errs) |err| {
                    if ((err.source == .client) == client_majority) continue;
                    try b.branch().case(b.x.dot().id(err.name_field)).body(b.x.valueOf(err.source));
                }

                const value: trt_refine.ErrorSource = if (client_majority) .client else .server;
                try b.@"else"().body(b.x.valueOf(value));
            }
        }.f).end();
    }
}

fn writeErrorSetRetryFn(members: []const SymbolsProvider.Error, bld: *zig.BlockBuild) !void {
    var true_count: usize = 0;
    for (members) |m| {
        if (m.retryable) true_count += 1;
    }

    if (true_count == 0) {
        try bld.discard().id("self").end();
        try bld.returns().valueOf(false).end();
    } else if (true_count == members.len) {
        try bld.discard().id("self").end();
        try bld.returns().valueOf(true).end();
    } else {
        const context = .{ .errs = members, .true_count = true_count };
        try bld.returns().switchWith(bld.x.id("self"), context, struct {
            fn f(ctx: @TypeOf(context), b: *zig.SwitchBuild) !void {
                const majority = ctx.true_count > ctx.errs.len - ctx.true_count;
                for (ctx.errs) |err| {
                    if (err.retryable == majority) continue;
                    try b.branch().case(b.x.dot().id(err.name_field)).body(b.x.valueOf(err.retryable));
                }

                try b.@"else"().body(b.x.valueOf(majority));
            }
        }.f).end();
    }
}

fn writeErrorSetStatusFn(members: []const SymbolsProvider.Error, bld: *zig.BlockBuild) !void {
    try bld.constant("status").typing(bld.x.raw("std.http.Status")).assign(
        bld.x.switchWith(bld.x.id("self"), members, struct {
            fn f(errs: []const SymbolsProvider.Error, b: *zig.SwitchBuild) !void {
                for (errs) |err| {
                    try b.branch()
                        .case(b.x.dot().id(err.name_field))
                        .body(b.x.valueOf(err.http_status));
                }
            }
        }.f),
    );

    try bld.returns().call("@enumFromInt", &.{bld.x.id("status")}).end();
}

test ClientOperation {
    var tester = try jobz.PipelineTester.init(.{});
    defer tester.deinit();

    var issues = IssuesBag.init(test_alloc);
    defer issues.deinit();
    _ = try tester.provideService(&issues, null);

    var symbols = try test_symbols.setup(tester.alloc(), .service);
    defer symbols.deinit();
    _ = try tester.provideService(&symbols, null);

    {
        var errors = std.ArrayList(SymbolsProvider.Error).init(tester.alloc());

        const service = (try symbols.getShape(symbols.service_id)).service;
        for (service.errors) |eid| try errors.append(try symbols.buildError(eid));

        symbols.service_errors = try errors.toOwnedSlice();
    }

    try srvc.expectServiceScript(
        \\const SerialType = smithy.SerialType;
        \\
        \\const srvc_types = @import("../data_types.zig");
        \\
        \\pub const MyOperation = struct {
        \\    pub const Result = smithy.Result(Output, ErrorKind);
        \\
        \\    pub const Input = struct {
        \\        foo: srvc_types.Foo,
        \\        bar: ?bool = null,
        \\    };
        \\
        \\    pub const Output = struct {
        \\        qux: ?[]const u8 = null,
        \\        arena: ?std.heap.ArenaAllocator = null,
        \\
        \\        pub fn deinit(self: @This()) void {
        \\            if (self.arena) |arena| arena.deinit();
        \\        }
        \\    };
        \\
        \\    pub const Error = smithy.ResultError(ErrorKind);
        \\
        \\    pub const ErrorKind = enum {
        \\        not_found,
        \\        service_error,
        \\
        \\        pub fn source(self: @This()) smithy.ErrorSource {
        \\            return switch (self) {
        \\                .not_found => .server,
        \\                else => .client,
        \\            };
        \\        }
        \\
        \\        pub fn httpStatus(self: @This()) std.http.Status {
        \\            const status: std.http.Status = switch (self) {
        \\                .not_found => .internal_server_error,
        \\                .service_error => .too_many_requests,
        \\            };
        \\
        \\            return @enumFromInt(status);
        \\        }
        \\
        \\        pub fn retryable(self: @This()) bool {
        \\            return switch (self) {
        \\                .service_error => true,
        \\                else => false,
        \\            };
        \\        }
        \\    };
        \\};
        \\
        \\pub const serial_input_scheme = .{ SerialType.structure, .{ .{
        \\    "Foo",
        \\    "foo",
        \\    true,
        \\    .{ SerialType.structure, .{} },
        \\}, .{
        \\    "Bar",
        \\    "bar",
        \\    false,
        \\    .{SerialType.boolean},
        \\} } };
        \\
        \\pub const serial_output_scheme = .{ SerialType.structure, .{.{
        \\    "Qux",
        \\    "qux",
        \\    false,
        \\    .{SerialType.string},
        \\}} };
        \\
        \\pub const serial_error_scheme = .{ SerialType.tagged_union, .{ .{
        \\    "NotFound",
        \\    "not_found",
        \\    .{},
        \\}, .{
        \\    "ServiceError",
        \\    "service_error",
        \\    .{},
        \\} } };
    , ClientOperation, tester.pipeline, .{SmithyId.of("test.serve#MyOperation")});
}
