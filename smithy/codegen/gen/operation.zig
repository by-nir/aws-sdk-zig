const std = @import("std");
const Allocator = std.mem.Allocator;
const jobz = @import("jobz");
const zig = @import("razdaz").zig;
const cfg = @import("../config.zig");
const syb = @import("../systems/symbols.zig");
const SmithyId = syb.SmithyId;
const SymbolsProvider = syb.SymbolsProvider;
const shape = @import("shape.zig");
const trt_auth = @import("../traits/auth.zig");
const trt_http = @import("../traits/http.zig");
const trt_refine = @import("../traits/refine.zig");
const trt_behave = @import("../traits/behavior.zig");

pub const OperationShapeHook = jobz.Task.Hook("Smithy Operation Shape", anyerror!void, &.{ *zig.BlockBuild, OperationShape });

pub const OperationShape = struct {
    id: SmithyId,
    input_type: ?[]const u8,
    output_type: ?[]const u8,
    errors_type: ?[]const u8,
    return_type: []const u8,
    auth_optional: bool,
    auth_schemes: []const trt_auth.AuthId,
};

pub fn writeOperationShapes(self: *const jobz.Delegate, symbols: *SymbolsProvider, bld: *zig.ContainerBuild, id: SmithyId) !void {
    const operation = (try symbols.getShape(id)).operation;

    if (operation.input) |in_id| {
        const members = (try symbols.getShape(in_id)).structure;
        try shape.writeStructShape(self, symbols, bld, in_id, members);
    }

    if (operation.output) |out_id| {
        const members = (try symbols.getShape(out_id)).structure;
        try shape.writeStructShape(self, symbols, bld, out_id, members);
    }
}

test writeOperationShapes {
    const OpTest = jobz.Task.Define("Operation Test", struct {
        fn eval(self: *const jobz.Delegate, symbols: *SymbolsProvider, bld: *zig.ContainerBuild) anyerror!void {
            try writeOperationShapes(self, symbols, bld, SmithyId.of("test.serve#Operation"));
        }
    }.eval, .{
        .injects = &.{SymbolsProvider},
    });

    try shape.shapeTester(&.{.service}, struct {
        fn eval(tester: *jobz.PipelineTester, bld: *zig.ContainerBuild) anyerror!void {
            try tester.runTask(OpTest, .{bld});
        }
    }.eval,
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
    );
}

pub fn writeOperationFunc(self: *const jobz.Delegate, symbols: *SymbolsProvider, bld: *zig.ContainerBuild, id: SmithyId) !void {
    const operation = (try symbols.getShape(id)).operation;
    const op_name = try symbols.getShapeName(id, .function);

    const service_errors = try symbols.getServiceErrors();
    const error_type = if (operation.errors.len + service_errors.len > 0)
        try errorSetName(self.alloc(), op_name, "srvc_errors.")
    else
        null;

    const input_type: ?[]const u8 = if (operation.input) |d| blk: {
        try symbols.markVisited(d);
        break :blk try symbols.getTypeName(d);
    } else null;
    const output_type: ?[]const u8 = if (operation.output) |d| blk: {
        try symbols.markVisited(d);
        break :blk try symbols.getTypeName(d);
    } else null;

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

    const op_shape = OperationShape{
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
            try ctx.self.evaluate(OperationShapeHook, .{ b, ctx.shape });
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
        \\pub fn operation(self: Client, allocator: Allocator, input: OperationInput) !smithy.Response(OperationOutput, srvc_errors.OperationError) {
        \\    return undefined;
        \\}
    );
}

const ErrorSetMember = struct {
    name: []const u8,
    code: u10,
    retryable: bool,
    source: trt_refine.Error.Source,
};

fn errorSetName(allocator: Allocator, shape_name: []const u8, comptime prefix: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, prefix ++ "{c}{s}Error", .{
        std.ascii.toUpper(shape_name[0]),
        shape_name[1..shape_name.len],
    });
}

pub const WriteErrorSet = jobz.Task.Define("Smithy Write Error Set", writeErrorSetTask, .{
    .injects = &.{SymbolsProvider},
});
fn writeErrorSetTask(
    self: *const jobz.Delegate,
    symbols: *SymbolsProvider,
    bld: *zig.ContainerBuild,
    shape_id: SmithyId,
    shape_errors: []const SmithyId,
    common_errors: []const SmithyId,
) anyerror!void {
    if (shape_errors.len + common_errors.len == 0) return;

    const shape_name = try symbols.getShapeName(shape_id, .type);
    const type_name = try errorSetName(self.alloc(), shape_name, "");

    const context = .{ .arena = self.alloc(), .symbols = symbols, .common_errors = common_errors, .shape_errors = shape_errors };
    try bld.public().constant(type_name).assign(bld.x.@"enum"().bodyWith(context, struct {
        fn f(ctx: @TypeOf(context), b: *zig.ContainerBuild) !void {
            var members = std.ArrayList(ErrorSetMember).init(ctx.arena);
            defer members.deinit();

            for (ctx.common_errors) |m| try writeErrorSetMember(ctx.arena, ctx.symbols, b, &members, m);
            for (ctx.shape_errors) |m| try writeErrorSetMember(ctx.arena, ctx.symbols, b, &members, m);

            try b.public().function("source")
                .arg("self", b.x.This())
                .returns(b.x.raw("smithy.ErrorSource"))
                .bodyWith(members.items, writeErrorSetSourceFn);

            try b.public().function("httpStatus")
                .arg("self", b.x.This())
                .returns(b.x.raw("std.http.Status"))
                .bodyWith(members.items, writeErrorSetStatusFn);

            try b.public().function("retryable")
                .arg("self", b.x.This())
                .returns(b.x.typeOf(bool))
                .bodyWith(members.items, writeErrorSetRetryFn);
        }
    }.f));
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

test WriteErrorSet {
    try shape.shapeTester(&.{ .service, .err }, struct {
        fn eval(tester: *jobz.PipelineTester, bld: *zig.ContainerBuild) anyerror!void {
            try tester.runTask(WriteErrorSet, .{
                bld,
                SmithyId.of("test.serve#Operation"),
                &.{SmithyId.of("test.error#NotFound")},
                &.{SmithyId.of("test#ServiceError")},
            });
        }
    }.eval, TEST_OPERATION_ERR);
}
pub const TEST_OPERATION_ERR =
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
;
