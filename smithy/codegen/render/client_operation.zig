const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const test_alloc = std.testing.allocator;
const jobz = @import("jobz");
const md = @import("codmod").md;
const zig = @import("codmod").zig;
const files_jobs = @import("codmod/jobs").files;
const shape = @import("shape.zig");
const schm = @import("scheme.zig");
const srvc = @import("service.zig");
const cfg = @import("../config.zig");
const SmithyId = @import("../model.zig").SmithyId;
const IssuesBag = @import("../systems/issues.zig").IssuesBag;
const SymbolsProvider = @import("../systems/SymbolsProvider.zig");
const name_util = @import("../utils/names.zig");
const trt_auth = @import("../traits/auth.zig");
const trt_refine = @import("../traits/refine.zig");
const trt_behavior = @import("../traits/behavior.zig");
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
    const arena = self.alloc();
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
    const errors = try listShapeErrors(arena, symbols, op.errors);

    try shape.writeDocComment(symbols, bld, id, false);

    const op_name = try symbols.getShapeName(id, .pascal, .{});
    const context = .{ .self = self, .symbols = symbols, .id = id, .name = op_name, .op = op, .errors = errors };
    try bld.public().constant(op_name).assign(
        bld.x.@"struct"().bodyWith(context, struct {
            fn f(ctx: @TypeOf(context), b: *zig.ContainerBuild) !void {
                const syb = ctx.symbols;
                const alloc = ctx.self.alloc();
                try b.field(cfg.alloc_param).typing(b.x.id("Allocator")).end();
                try b.field("client").typing(b.x.typePointer(false, b.x.raw(cfg.service_client_type))).end();
                if (ctx.op.input != null) try b.field("input").typing(b.x.id("Input")).end();

                if (trt_behavior.Paginated.get(syb, ctx.id)) |pg| {
                    var paginated = pg;
                    if (paginated.isPartial()) if (trt_behavior.Paginated.get(syb, syb.service_id)) |service| {
                        if (pg.page_size == null) paginated.page_size = service.page_size;
                        if (pg.items == null) paginated.items = service.items orelse return error.IncompletePaginated;
                        if (pg.input_token == null) paginated.input_token = service.input_token orelse return error.IncompletePaginated;
                        if (pg.output_token == null) paginated.output_token = service.output_token orelse return error.IncompletePaginated;
                    };

                    const output_shape = if (ctx.op.output) |oid| try ctx.symbols.getShapeNameFull(oid) else null;
                    const page_ctx = PageContext{
                        .arena = alloc,
                        .symbols = syb,
                        .has_input = ctx.op.input != null,
                        .paginated = paginated,
                        .output_shape_name = output_shape,
                    };

                    try b.field("pages_complete").typing(b.x.typeOf(bool)).assign(b.x.valueOf(false));

                    try b.public().function("nextPage")
                        .arg("self", b.x.typePointer(true, b.x.id(ctx.name)))
                        .returns(b.x.typeError(null, b.x.typeOptional(b.x.id("Result"))))
                        .bodyWith(page_ctx, writeNextPageFunc);
                } else {
                    try b.public().function("send")
                        .arg("self", b.x.This())
                        .returns(b.x.typeError(null, b.x.id("Result")))
                        .bodyWith(ctx.op.input != null, writeSendFunc);
                }

                const auth_optional = syb.hasTrait(ctx.id, trt_auth.optional_auth_id);
                const auth_schemes = trt_auth.Auth.get(syb, ctx.id) orelse
                    trt_auth.Auth.get(syb, syb.service_id) orelse
                    syb.service_auth_schemes;

                var auth_exprs = try std.ArrayList(zig.ExprBuild).initCapacity(alloc, auth_schemes.len);
                for (auth_schemes) |aid| {
                    const string = b.x.valueOf(try alloc.dupe(u8, aid.toString()));
                    auth_exprs.appendAssumeCapacity(
                        b.x.id(cfg.runtime_scope).dot().id("AuthId").dot().call("of", &.{string}),
                    );
                }

                var meta = try std.ArrayList(zig.ExprBuild).initCapacity(alloc, 10);
                meta.appendAssumeCapacity(b.x.structAssign("name", b.x.valueOf(ctx.name)));
                meta.appendAssumeCapacity(b.x.structAssign("Input", if (ctx.op.input) |_| b.x.id("Input") else b.x.typeOf(void)));
                meta.appendAssumeCapacity(b.x.structAssign("Output", if (ctx.op.output) |_| b.x.id("Output") else b.x.typeOf(void)));
                meta.appendAssumeCapacity(b.x.structAssign("Errors", if (ctx.errors.len > 0) b.x.id("ErrorKind") else b.x.typeOf(void)));
                meta.appendAssumeCapacity(b.x.structAssign("Result", b.x.id("Result")));
                meta.appendAssumeCapacity(b.x.structAssign("scheme_input", if (ctx.op.input) |_| b.x.id("scheme_input") else b.x.raw(".{}")));
                meta.appendAssumeCapacity(b.x.structAssign("scheme_output", if (ctx.op.output) |_| b.x.id("scheme_output") else b.x.raw(".{}")));
                meta.appendAssumeCapacity(b.x.structAssign("scheme_errors", if (ctx.errors.len > 0) b.x.id("scheme_errors") else b.x.raw(".{}")));
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
                    try shape.writeShapeDecleration(alloc, syb, b, in_id, .{
                        .identifier = "Input",
                        .scope = cfg.types_scope,
                        .behavior = .input,
                    });
                }

                if (ctx.op.output) |out_id| {
                    try shape.writeShapeDecleration(alloc, syb, b, out_id, .{
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
                        .arena = alloc,
                        .symbols = syb,
                        .members = ctx.errors,
                    }, writeErrorSet));
                }
            }
        }.f),
    );

    if (op.input) |in_id| {
        const scheme = try schm.operationTransportScheme(arena, symbols, bld.x, in_id);
        try bld.constant("scheme_input").assign(scheme);
    }

    if (op.output) |out_id| {
        const scheme = try schm.operationTransportScheme(arena, symbols, bld.x, out_id);
        try bld.constant("scheme_output").assign(scheme);
    }

    if (errors.len > 0) {
        const scheme = try schm.operationErrorScheme(arena, bld.x, errors);
        try bld.constant("scheme_errors").assign(scheme);
    }
}

fn writeSendFunc(has_input: bool, bld: *zig.BlockBuild) !void {
    try bld.returns().fromExpr(try buildSendOperation(has_input, bld.x)).end();
}

fn buildSendOperation(has_input: bool, expr: zig.ExprBuild) !zig.Expr {
    return expr.raw("self.client").dot().call("_sendSync", &.{
        expr.raw("self.allocator"),
        expr.id("operation_meta"),
        if (has_input) expr.raw("self.input") else expr.valueOf({}),
    }).consume();
}

const PageContext = struct {
    arena: Allocator,
    has_input: bool,
    symbols: *SymbolsProvider,
    paginated: trt_behavior.Paginated.Val,
    output_shape_name: ?[]const u8 = null,
};

fn writeNextPageFunc(ctx: PageContext, bld: *zig.BlockBuild) !void {
    try bld.@"if"(bld.x.raw("self.pages_complete"))
        .body(bld.x.returns().valueOf(null))
        .end();

    try bld.constant("response").assign(
        bld.x.trys().fromExpr(try buildSendOperation(ctx.has_input, bld.x)),
    );

    try bld.@"if"(bld.x.id("response").op(.eql).valueOf(.ok)).body(bld.x.blockWith(ctx, struct {
        fn f(c: PageContext, b: *zig.BlockBuild) !void {
            const input_path = (try pathStringExpr(c.arena, c.symbols, null, c.paginated.input_token.?)).normal;
            const otk = try pathStringExpr(c.arena, c.symbols, c.output_shape_name, c.paginated.output_token.?);
            switch (otk) {
                .normal => |output_path| try writeNextPageRequired(b, input_path, output_path),
                .optional => |o| try writeNextPageOptional(b, input_path, o[0], o[1]),
            }
        }
    }.f)).end();

    try bld.returns().id("response").end();
}

fn writeNextPageRequired(bld: *zig.BlockBuild, input_path: []const u8, output_path: []const u8) !void {
    try bld.@"if"(bld.x.raw("response.ok").dot().raw(output_path)).capture("token")
        .body(bld.x.raw("self.input.").raw(input_path).assign().id("token"))
        .@"else"().body(bld.x.raw("self.pages_complete = true"))
        .end();
}

fn writeNextPageOptional(
    bld: *zig.BlockBuild,
    input_path: []const u8,
    output_field: []const u8,
    output_path: []const u8,
) !void {
    const parent = bld.x.raw("response.ok").dot().raw(output_field);
    try bld.@"if"(
        parent.op(.not_eql).valueOf(null).op(.@"and")
            .buildExpr(parent).unwrap().raw(output_path).op(.not_eql).valueOf(null),
    ).body(
        bld.x.raw("self.input").dot().raw(input_path).assign().buildExpr(parent).unwrap().raw(output_path).unwrap(),
    ).@"else"().body(
        bld.x.raw("self.pages_complete = true"),
    ).end();
}

const PathExpr = union(enum) {
    normal: []const u8,
    /// First path is the optional part, the second is the required part.
    optional: [2][]const u8,
};

/// When provided with `parent` will check if the first field is optional.
/// Otherwise, it will assume the first field is always required.
fn pathStringExpr(arena: Allocator, symbols: *SymbolsProvider, parent: ?[]const u8, path: []const u8) !PathExpr {
    var optional: ?[]const u8 = null;
    var buffer = std.ArrayList(u8).init(arena);
    errdefer buffer.deinit();

    var pos: usize = 0;
    while (pos < path.len) {
        const i = mem.indexOfAnyPos(u8, path, pos, ".[") orelse path.len;
        const is_last = i == path.len;

        const raw_field = path[pos..i];
        const field = try name_util.formatCase(arena, .snake, raw_field);
        // We ignore if single direct field – as it will already be null-checked.
        if (parent == null or pos > 0 or is_last) {
            try buffer.appendSlice(field);
        } else {
            const member_id = SmithyId.compose(parent.?, raw_field);
            if (!symbols.hasTrait(member_id, trt_refine.required_id)) {
                optional = field;
            } else {
                try buffer.appendSlice(field);
            }
        }

        if (is_last) break;

        switch (path[i]) {
            '.' => {
                try buffer.append('.');
                pos = i + 1;
            },
            '[' => {
                const end = mem.indexOfScalarPos(u8, path, i + 2, ']').?;
                try buffer.appendSlice(path[i .. end + 1]);
                break; // Indexer may only be the last part of the path.
            },
            else => unreachable,
        }
    }

    const full_path = try buffer.toOwnedSlice();
    if (optional) |opt| {
        return .{ .optional = .{ opt, full_path } };
    } else {
        return .{ .normal = full_path };
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

    outer: for (symbols.service_errors) |srvc_err| {
        for (members.items[0..shape_errors.len]) |op_err| {
            if (mem.eql(u8, op_err.name_api, srvc_err.name_api)) continue :outer;
            if (mem.eql(u8, op_err.name_zig, srvc_err.name_zig)) continue :outer;
        }

        try members.append(srvc_err);
    }

    return members.toOwnedSlice();
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

    try bld.field(member.name_zig).end();
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
                    try b.branch().case(b.x.dot().id(err.name_zig)).body(b.x.valueOf(err.source));
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
                    try b.branch().case(b.x.dot().id(err.name_zig)).body(b.x.valueOf(err.retryable));
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
                        .case(b.x.dot().id(err.name_zig))
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
        \\        .scheme_input = scheme_input,
        \\        .scheme_output = scheme_output,
        \\        .scheme_errors = scheme_errors,
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
        \\const scheme_input = .{
        \\    .name_api = "MyOperationInput",
        \\    .meta = .{},
        \\    .body_ids = .{ 0, 1 },
        \\    .members = .{ .{
        \\        .name_api = "Foo",
        \\        .name_zig = "foo",
        \\        .required = true,
        \\        .scheme = .{ .shape = SerialType.structure, .members = .{} },
        \\    }, .{
        \\        .name_api = "Bar",
        \\        .name_zig = "bar",
        \\        .scheme = .{.shape = SerialType.string},
        \\    } },
        \\};
        \\
        \\const scheme_output = .{
        \\    .name_api = "MyOperationOutput",
        \\    .meta = .{},
        \\    .body_ids = .{0},
        \\    .members = .{.{
        \\        .name_api = "Qux",
        \\        .name_zig = "qux",
        \\        .scheme = .{.shape = SerialType.string},
        \\    }},
        \\};
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
