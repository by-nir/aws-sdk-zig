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
const mdl = @import("../model.zig");
const SmithyId = mdl.SmithyId;
const SmithyOperation = mdl.SmithyOperation;
const IssuesBag = @import("../systems/issues.zig").IssuesBag;
const SymbolsProvider = @import("../systems/SymbolsProvider.zig");
const name_util = @import("../utils/names.zig");
const trt_auth = @import("../traits/auth.zig");
const trt_refine = @import("../traits/refine.zig");
const trt_protocol = @import("../traits/protocol.zig");
const test_symbols = @import("../testing/symbols.zig");

pub const OperationScriptHeadHook = jobz.Task.Hook("Smithy Operation Script Head", anyerror!void, &.{ *zig.ContainerBuild, SmithyId });
pub const OperationMetaHook = jobz.Task.Hook("Smithy Operation Meta", anyerror!void, &.{ *std.ArrayList(zig.ExprBuild), zig.ExprBuild, SmithyId });

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
    .injects = &.{SymbolsProvider},
});
fn clientOperationTask(
    self: *const jobz.Delegate,
    symbols: *SymbolsProvider,
    bld: *zig.ContainerBuild,
    id: SmithyId,
) anyerror!void {
    try bld.constant("SerialType").assign(bld.x.id(cfg.runtime_scope).dot().id("SerialType"));

    if (symbols.service_operations.len > 0) {
        try bld.constant(cfg.types_scope).assign(bld.x.import("../" ++ cfg.types_filename));
    }

    if (symbols.service_operations.len > 0) {
        try bld.constant(cfg.service_client_type).assign(
            bld.x.import("../" ++ cfg.service_client_filename).dot().id(cfg.service_client_type),
        );
    }

    if (self.hasOverride(OperationScriptHeadHook)) {
        try self.evaluate(OperationScriptHeadHook, .{ bld, id });
    }

    const op = (try symbols.getShape(id)).operation;
    const errors = try listShapeErrors(self.alloc(), symbols, op.errors);

    const op_name = try symbols.getShapeName(id, .pascal, .{});
    const context = .{ .self = self, .symbols = symbols, .id = id, .name = op_name, .op = op, .errors = errors };
    try bld.public().constant(op_name).assign(
        bld.x.@"struct"().bodyWith(context, struct {
            fn f(ctx: @TypeOf(context), b: *zig.ContainerBuild) !void {
                const arena = ctx.self.alloc();
                try b.field(cfg.alloc_param).typing(b.x.id("Allocator")).end();
                try b.field("client").typing(b.x.typePointer(false, b.x.raw(cfg.service_client_type))).end();
                if (ctx.op.input != null) try b.field("input").typing(b.x.id("Input")).end();

                try b.public().function("send")
                    .arg("self", b.x.This())
                    .returns(b.x.typeError(null, b.x.id("Result")))
                    .bodyWith(ctx.op.input != null, sendFunc);

                const auth_optional = ctx.symbols.hasTrait(ctx.id, trt_auth.optional_auth_id);
                const auth_schemes = trt_auth.Auth.get(ctx.symbols, ctx.id) orelse
                    trt_auth.Auth.get(ctx.symbols, ctx.symbols.service_id) orelse
                    ctx.symbols.service_auth_schemes;

                var auth_exprs = try std.ArrayList(zig.ExprBuild).initCapacity(arena, auth_schemes.len);
                for (auth_schemes) |aid| {
                    const string = b.x.valueOf(try arena.dupe(u8, aid.toString()));
                    auth_exprs.appendAssumeCapacity(
                        b.x.id(cfg.runtime_scope).dot().id("AuthId").dot().call("of", &.{string}),
                    );
                }

                var meta = try std.ArrayList(zig.ExprBuild).initCapacity(arena, 10);
                meta.appendAssumeCapacity(b.x.structAssign("name", b.x.valueOf(ctx.name)));
                meta.appendAssumeCapacity(b.x.structAssign("Input", if (ctx.op.input) |_| b.x.id("Input") else b.x.typeOf(void)));
                meta.appendAssumeCapacity(b.x.structAssign("Output", if (ctx.op.output) |_| b.x.id("Output") else b.x.typeOf(void)));
                meta.appendAssumeCapacity(b.x.structAssign("Errors", if (ctx.errors.len > 0) b.x.id("ErrorKind") else b.x.typeOf(void)));
                meta.appendAssumeCapacity(b.x.structAssign("Result", b.x.id("Result")));
                meta.appendAssumeCapacity(b.x.structAssign("serial_input", if (ctx.op.input) |_| b.x.id("scheme_input") else b.x.raw(".{}")));
                meta.appendAssumeCapacity(b.x.structAssign("serial_output", if (ctx.op.output) |_| b.x.id("scheme_output") else b.x.raw(".{}")));
                meta.appendAssumeCapacity(b.x.structAssign("serial_errors", if (ctx.errors.len > 0) b.x.id("scheme_errors") else b.x.raw(".{}")));
                meta.appendAssumeCapacity(b.x.structAssign("auth_optional", b.x.valueOf(auth_optional)));
                meta.appendAssumeCapacity(b.x.structAssign("auth_schemes", b.x.addressOf().structLiteral(null, auth_exprs.items)));
                if (ctx.self.hasOverride(OperationMetaHook)) {
                    try ctx.self.evaluate(OperationMetaHook, .{ &meta, b.x, ctx.id });
                }
                try b.constant("operation_meta").assign(b.x.structLiteral(null, meta.items));

                try b.public().constant("Result").assign(blk: {
                    const payload = if (ctx.op.output != null) b.x.id("Output") else b.x.typeOf(void);
                    if (ctx.errors.len > 0) {
                        break :blk b.x.raw(cfg.runtime_scope).dot().call("Result", &.{ payload, b.x.id("ErrorKind") });
                    } else {
                        break :blk payload;
                    }
                });

                if (ctx.op.input) |in_id| {
                    try shape.writeShapeDecleration(arena, ctx.symbols, b, in_id, .{
                        .identifier = "Input",
                        .scope = cfg.types_scope,
                        .behavior = .input,
                    });
                }

                if (ctx.op.output) |out_id| {
                    try shape.writeShapeDecleration(arena, ctx.symbols, b, out_id, .{
                        .identifier = "Output",
                        .scope = cfg.types_scope,
                        .behavior = .output,
                    });
                }

                if (ctx.errors.len > 0) {
                    try b.public().constant("Error").assign(b.x.raw(cfg.runtime_scope).dot().call("ResultError", &.{
                        b.x.id("ErrorKind"),
                    }));

                    try b.public().constant("ErrorKind").assign(b.x.@"enum"().bodyWith(ErrorSetCtx{
                        .arena = arena,
                        .symbols = ctx.symbols,
                        .members = ctx.errors,
                    }, writeErrorSet));
                }
            }
        }.f),
    );

    if (op.input) |in_id| {
        const scheme = try serialShapeScheme(self, symbols, bld.x, in_id);
        try bld.constant("scheme_input").assign(scheme);
    }

    if (op.output) |out_id| {
        const scheme = try serialShapeScheme(self, symbols, bld.x, out_id);
        try bld.constant("scheme_output").assign(scheme);
    }

    if (errors.len > 0) {
        const scheme = try serialErrorScheme(self, bld.x, errors);
        try bld.constant("scheme_errors").assign(scheme);
    }
}

fn sendFunc(has_input: bool, bld: *zig.BlockBuild) !void {
    try bld.returns().raw("self.client").dot().call("_sendSync", &.{
        bld.x.raw("self.allocator"),
        bld.x.id("operation_meta"),
        if (has_input) bld.x.raw("self.input") else bld.x.valueOf({}),
    }).end();
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

    outer: for (symbols.service_errors) |srvc_err| {
        for (members.items[0..shape_errors.len]) |op_err| {
            if (std.mem.eql(u8, op_err.name_api, srvc_err.name_api)) continue :outer;
            if (std.mem.eql(u8, op_err.name_field, srvc_err.name_field)) continue :outer;
        }

        try members.append(srvc_err);
    }

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
        => |_, g| return exp.structLiteral(null, &.{exp.id("SerialType").valueOf(g)}),
        .timestamp => {
            const format = trt_protocol.TimestampFormat.get(symbols, id) orelse symbols.service_timestamp_fmt;
            const literal = switch (format) {
                .date_time => ".timestamp_date_time",
                .http_date => ".timestamp_http_date",
                .epoch_seconds => ".timestamp_epoch_seconds",
            };
            return exp.structLiteral(null, &.{exp.id("SerialType").raw(literal)});
        },
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
        .document => {
            // AWS usage: controltower, identitystore, inspector-scan, bedrock-agent-runtime, marketplace-catalog
            @panic("Document shape scheme construction not implemented");
        },
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
        \\const Client = @import("../client.zig").Client;
        \\
        \\pub const MyOperation = struct {
        \\    allocator: Allocator,
        \\    client: *const Client,
        \\    input: Input,
        \\
        \\    pub fn send(self: @This()) !Result {
        \\        return self.client._sendSync(self.allocator, operation_meta, self.input);
        \\    }
        \\
        \\    const operation_meta = .{
        \\        .name = "MyOperation",
        \\        .Input = Input,
        \\        .Output = Output,
        \\        .Errors = ErrorKind,
        \\        .Result = Result,
        \\        .serial_input = scheme_input,
        \\        .serial_output = scheme_output,
        \\        .serial_errors = scheme_errors,
        \\        .auth_optional = false,
        \\        .auth_schemes = &.{},
        \\    };
        \\
        \\    pub const Result = smithy.Result(Output, ErrorKind);
        \\
        \\    pub const Input = struct {
        \\        foo: srvc_types.Foo,
        \\        bar: ?[]const u8 = null,
        \\
        \\        pub fn validate(self: @This()) !void {
        \\            if (self.bar) |t| try smithy.validate.stringLength(.Service, "MyOperationInput", "bar", null, 128, t);
        \\        }
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
        \\const scheme_input = .{ SerialType.structure, .{ .{
        \\    "Foo",
        \\    "foo",
        \\    true,
        \\    .{ SerialType.structure, .{} },
        \\}, .{
        \\    "Bar",
        \\    "bar",
        \\    false,
        \\    .{SerialType.string},
        \\} } };
        \\
        \\const scheme_output = .{ SerialType.structure, .{.{
        \\    "Qux",
        \\    "qux",
        \\    false,
        \\    .{SerialType.string},
        \\}} };
        \\
        \\const scheme_errors = .{ SerialType.tagged_union, .{ .{
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
