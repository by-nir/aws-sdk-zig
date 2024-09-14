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

pub fn operationFilename(symbols: *SymbolsProvider, id: SmithyId, comptime nested: bool) ![]const u8 {
    return try symbols.getShapeName(id, .snake, .{
        .prefix = if (nested) "" else "operation/",
        .suffix = ".zig",
    });
}

pub const ClientOperationsDir = files_jobs.OpenDir.Task("Smithy Codegen Client Operations Directory", clientOperationsDirTask, .{
    .injects = &.{SymbolsProvider},
});
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
    const operation = if (try shape.getShapeSafe(self, symbols, issues, id)) |s| s.operation else return;

    if (symbols.service_operations.len > 0) {
        try bld.constant(cfg.types_scope).assign(bld.x.import("../" ++ cfg.types_filename));
    }

    if (self.hasOverride(OperationScriptHeadHook)) {
        try self.evaluate(OperationScriptHeadHook, .{ bld, id });
    }

    if (operation.input) |in_id| {
        const hint = try serialShapeHint(self, symbols, bld.x, in_id);
        try bld.public().constant("serial_input_hint").assign(hint);

        const members = (try symbols.getShape(in_id)).structure;
        try shape.writeStructShape(symbols, bld, in_id, members, true, "OperationInput");
    }

    if (operation.output) |out_id| {
        const hint = try serialShapeHint(self, symbols, bld.x, out_id);
        try bld.public().constant("serial_output_hint").assign(hint);

        const members = (try symbols.getShape(out_id)).structure;
        try shape.writeStructShape(symbols, bld, out_id, members, true, "OperationOutput");
    }

    if (symbols.service_errors.len + operation.errors.len > 0) {
        const hint = try serialErrorHint(self, symbols, bld.x, operation.errors, symbols.service_errors);
        try bld.public().constant("serial_error_hint").assign(hint);

        try bld.public().constant("OperationError").assign(bld.x.@"enum"().bodyWith(ErrorSetCtx{
            .arena = self.alloc(),
            .symbols = symbols,
            .shape_errors = operation.errors,
            .common_errors = symbols.service_errors,
        }, writeErrorSet));
    }
}

fn serialShapeHint(
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
        => |_, g| {
            return exp.valueOf(g);
        },
        .list => |child| {
            const variant = switch (shape.listType(symbols, id)) {
                .standard => "list",
                .sparse => "list_sparse",
                .set => "set",
            };
            const member_hint = try serialShapeHint(self, symbols, exp, child);
            return exp.structLiteral(null, &.{exp.structAssign(variant, member_hint)});
        },
        .map => |children| {
            const typing = try shape.mapType(symbols, id, children[0]);
            const variant = if (typing.sparse) "map_sparse" else "map";
            const key_hint = if (typing.string)
                exp.valueOf(.string)
            else
                try serialShapeHint(self, symbols, exp, children[0]);

            return exp.structLiteral(null, &.{exp.structAssign(variant, exp.structLiteral(null, &.{
                key_hint,
                try serialShapeHint(self, symbols, exp, children[1]),
            }))});
        },
        inline .structure, .tagged_uinon => |members, g| {
            var hints = std.ArrayList(zig.ExprBuild).init(self.alloc());
            const is_input = symbols.hasTrait(id, trt_refine.input_id);

            for (members) |member| {
                const name_raw = exp.valueOf(try symbols.getShapeName(member, .pascal, .{}));
                const name_field = exp.valueOf(try symbols.getShapeName(member, .snake, .{}));
                const is_required = exp.valueOf(!shape.isStructShapeMemberOptional(symbols, member, is_input));
                const member_hint = try serialShapeHint(self, symbols, exp, member);
                try hints.append(exp.structLiteral(null, &.{ name_raw, name_field, is_required, member_hint }));
            }

            const hints_expr = exp.structAssign(@tagName(g), exp.structLiteral(null, try hints.toOwnedSlice()));
            return exp.structLiteral(null, &.{hints_expr});
        },
        .unit, .document, .operation, .resource, .service, .target => @panic("unexpected serial hint shape type"),
    }
}

fn serialErrorHint(
    self: *const jobz.Delegate,
    symbols: *SymbolsProvider,
    exp: zig.ExprBuild,
    common_errors: []const SmithyId,
    shape_errors: []const SmithyId,
) !zig.ExprBuild {
    var hints = std.ArrayList(zig.ExprBuild).init(self.alloc());
    for ([2][]const SmithyId{ shape_errors, common_errors }) |id_list| {
        for (id_list) |id| {
            const name_raw = exp.valueOf(try symbols.getShapeName(id, .pascal, .{}));
            const name_field = exp.valueOf(try getErrorName(symbols, id));
            try hints.append(exp.structLiteral(null, &.{ name_raw, name_field, exp.structLiteral(null, &.{}) }));
        }
    }
    return exp.structLiteral(null, try hints.toOwnedSlice());
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

    for (ctx.shape_errors) |m| try writeErrorSetMember(ctx.symbols, bld, &members, m);
    for (ctx.common_errors) |m| try writeErrorSetMember(ctx.symbols, bld, &members, m);

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
    symbols: *SymbolsProvider,
    bld: *zig.ContainerBuild,
    list: *std.ArrayList(ErrorSetMember),
    member: SmithyId,
) !void {
    try shape.writeDocComment(symbols, bld, member, true);
    const shape_name = try getErrorName(symbols, member);
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

fn getErrorName(symbols: *SymbolsProvider, id: SmithyId) ![]const u8 {
    var shape_name = try symbols.getShapeName(id, .snake, .{});
    inline for (.{ "_error", "_exception" }) |suffix| {
        if (std.ascii.endsWithIgnoreCase(shape_name, suffix)) {
            shape_name = shape_name[0 .. shape_name.len - suffix.len];
            break;
        }
    }
    return shape_name;
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
        \\const srvc_types = @import("../data_types.zig");
        \\
        \\pub const serial_input_hint = .{.structure = .{ .{
        \\    "Foo",
        \\    "foo",
        \\    true,
        \\    .{.structure = .{}},
        \\}, .{
        \\    "Bar",
        \\    "bar",
        \\    false,
        \\    .boolean,
        \\} }};
        \\
        \\pub const OperationInput = struct {
        \\    foo: srvc_types.Foo,
        \\    bar: ?bool = null,
        \\};
        \\
        \\pub const serial_output_hint = .{.structure = .{}};
        \\
        \\pub const OperationOutput = struct {};
        \\
        \\pub const serial_error_hint = .{ .{
        \\    "ServiceError",
        \\    "service",
        \\    .{},
        \\}, .{
        \\    "NotFound",
        \\    "not_found",
        \\    .{},
        \\} };
        \\
        \\pub const OperationError = enum {
        \\    not_found,
        \\    service,
        \\
        \\    pub fn source(self: @This()) smithy.ErrorSource {
        \\        return switch (self) {
        \\            .not_found => .server,
        \\            .service => .client,
        \\        };
        \\    }
        \\
        \\    pub fn httpStatus(self: @This()) std.http.Status {
        \\        const code = switch (self) {
        \\            .not_found => 500,
        \\            .service => 429,
        \\        };
        \\
        \\        return @enumFromInt(code);
        \\    }
        \\
        \\    pub fn retryable(self: @This()) bool {
        \\        return switch (self) {
        \\            .not_found => false,
        \\            .service => true,
        \\        };
        \\    }
        \\};
    , ClientOperation, tester.pipeline, .{SmithyId.of("test.serve#Operation")});
}
