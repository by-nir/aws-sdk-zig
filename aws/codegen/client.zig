const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const allocPrint = std.fmt.allocPrint;
const smithy = @import("smithy");
const Script = smithy.Script;
const Expr = Script.Expr;
const Pipeline = smithy.Pipeline;
const PipelineHooks = Pipeline.Hooks;
const SmithyModel = smithy.SmithyModel;
const SmithyService = smithy.SmithyService;
const GenerateHooks = smithy.GenerateHooks;
const trt_iam = @import("integrate/iam.zig");
const trt_auth = @import("integrate/auth.zig");
const trt_core = @import("integrate/core.zig");
const trt_gateway = @import("integrate/gateway.zig");
const trt_endpoint = @import("integrate/endpoints.zig");
const trt_protocol = @import("integrate/protocols.zig");
const trt_cloudform = @import("integrate/cloudformation.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa_alloc = gpa.allocator();
    defer _ = gpa.deinit();

    const args = try std.process.argsAlloc(gpa_alloc);
    defer std.process.argsFree(gpa_alloc, args);
    if (args.len < 3) return error.MissingPathsArgs;

    var pipeline = try Pipeline.init(gpa_alloc, std.heap.page_allocator, .{
        .src_dir_absolute = args[1],
        .out_dir_relative = args[2],
        .parse_policy = .{ .property = .abort, .trait = .skip },
        .codegen_policy = .{
            .unknown_shape = .abort,
            .invalid_root = .abort,
            .shape_codegen_fail = .abort,
        },
        .process_policy = .{
            .model = .skip,
            .readme = .abort,
        },
    }, .{
        .writeReadme = writeReadme,
    }, .{
        .writeScriptHead = writeScriptHead,
        .uniqueListType = uniqueListType,
        .writeErrorShape = writeErrorShape,
        .writeServiceHead = writeServiceHead,
        .operationReturnType = operationReturnType,
        .writeOperationBody = writeOperationBody,
    });
    defer pipeline.deinit();

    try pipeline.registerTraits(trt_auth.traits);
    try pipeline.registerTraits(trt_cloudform.traits);
    try pipeline.registerTraits(trt_core.traits);
    try pipeline.registerTraits(trt_endpoint.traits);
    try pipeline.registerTraits(trt_gateway.traits);
    try pipeline.registerTraits(trt_iam.traits);
    try pipeline.registerTraits(trt_protocol.traits);

    const whitelist = args[3..args.len];
    if (whitelist.len == 0) {
        _ = try pipeline.processAll(filterSourceModel);
    } else {
        var files = try std.ArrayList([]const u8).initCapacity(gpa_alloc, whitelist.len);
        defer {
            for (files.items) |file| {
                gpa_alloc.free(file);
            }
            files.deinit();
        }
        for (whitelist) |filename| {
            try files.append(try allocPrint(gpa_alloc, "{s}.json", .{filename}));
        }
        _ = try pipeline.processFiles(files.items);
    }

}

fn filterSourceModel(filename: []const u8) bool {
    return !std.mem.startsWith(u8, filename, "sdk-");
}

fn writeReadme(
    arena: Allocator,
    output: std.io.AnyWriter,
    model: *const SmithyModel,
    src_meta: PipelineHooks.ReadmeMeta,
) !void {
    var meta = src_meta;
    if (trt_core.Service.get(model, model.service)) |service| {
        if (std.mem.startsWith(u8, service.sdk_id, "AWS")) {
            meta.title = service.sdk_id;
        } else {
            meta.title = try allocPrint(arena, "AWS {s}", .{service.sdk_id});
        }
    }

    try output.print(@embedFile("template/README.head.md.template"), .{
        .title = meta.title,
        .slug = meta.slug,
    });
    if (src_meta.intro) |intro| {
        try output.writeByte('\n');
        try output.writeAll(intro);
        try output.writeByte('\n');
    }
    try output.print(@embedFile("template/README.install.md.template"), .{});
    try output.print(@embedFile("template/README.footer.md.template"), .{
        .title = meta.title,
    });
}

fn writeScriptHead(arena: Allocator, script: *Script, model: *const SmithyModel) !void {
    _ = try script.import("std");

    const aws_types = try script.import("aws-types");
    _ = try script.variable(.{}, .{
        .identifier = .{ .name = "ErrorSource" },
        .type = null,
    }, .{ .raw = try aws_types.child(arena, "ErrorSource") });
    _ = try script.variable(.{}, .{
        .identifier = .{ .name = "Failable" },
        .type = null,
    }, .{ .raw = try aws_types.child(arena, "Failable") });

    const runtime = try script.import("aws-runtime");
    _ = try script.variable(.{}, .{
        .identifier = .{ .name = "Runtime" },
        .type = null,
    }, .{ .raw = try runtime.child(arena, "Client") });
    _ = try script.variable(.{}, .{
        .identifier = .{ .name = "Signer" },
        .type = null,
    }, .{ .raw = try runtime.child(arena, "Signer") });
    _ = try script.variable(.{}, .{
        .identifier = .{ .name = "Endpoint" },
        .type = null,
    }, .{ .raw = try runtime.child(arena, "Endpoint") });

    const service = trt_core.Service.get(model, model.service) orelse return error.MissingService;
    const service_endpoint = service.endpoint_prefix orelse return error.MissingServiceEndpoint;

    _ = try script.variable(.{}, .{
        .identifier = .{ .name = "endpoint_config" },
        .type = null,
    }, Expr.structLiteral(".", &.{
        .{ .raw = try allocPrint(arena, ".name = \"{s}\"", .{service_endpoint}) },
    }));
}

fn writeServiceHead(arena: Allocator, script: *Script, model: *const SmithyModel, shape: *const SmithyService) !void {
    _ = try script.field(.{
        .name = "runtime",
        .type = .{ .raw = "*Runtime" },
    });
    _ = try script.field(.{
        .name = "signer",
        .type = .{ .raw = "Signer" },
    });
    _ = try script.field(.{
        .name = "endpoint",
        .type = .{ .raw = "Endpoint" },
    });

    //
    // Init function
    //

    var block = try script.function(.{
        .is_public = true,
    }, .{
        .identifier = .{ .name = "init" },
        .parameters = &.{
            .{
                .identifier = .{ .name = "region" },
                .type = null,
            },
            .{
                .identifier = .{ .name = "auth" },
                .type = null,
            },
        },
        .return_type = .typ_This,
    });
    try block.expr(.{ .raw = "_ = region" });
    try block.expr(.{ .raw = "_ = auth" });
    try block.destruct(
        &.{.{ .unmut = .{ .name = "runtime" } }},
        .{ .raw = "Runtime.retain()" },
    );
    try block.destruct(
        &.{.{ .unmut = .{ .name = "signer" } }},
        .{ .raw = "undefined" },
    );
    try block.destruct(
        &.{.{ .unmut = .{ .name = "endpoint" } }},
        .{ .raw = "undefined" },
    );
    try block.prefix(.ret).expr(.{ .raw = ".{ .runtime = runtime, .signer = signer, .endpoint = endpoint }" });
    try block.end();

    //
    // Deinit function
    //

    block = try script.function(.{
        .is_public = true,
    }, .{
        .identifier = .{ .name = "deinit" },
        .parameters = &.{Script.param_self},
        .return_type = null,
    });
    try block.expr(.{ .raw = "self.runtime.release()" });
    try block.expr(.{ .raw = "self.endpoint.deinit()" });
    try block.end();

    _ = arena; // autofix
    _ = model; // autofix
    _ = shape; // autofix
}

fn operationReturnType(arena: Allocator, _: *const SmithyModel, shape: GenerateHooks.OperationShape) !?Expr {
    return if (shape.errors_type) |errors| blk: {
        const args = try arena.alloc(Expr, 2);
        args[0] = shape.output_type orelse Expr.typ(void);
        args[1] = errors;
        break :blk Expr.call("Failable", args);
    } else shape.output_type;
}

fn writeOperationBody(
    _: Allocator,
    body: *Script.Scope,
    model: *const SmithyModel,
    shape: GenerateHooks.OperationShape,
) !void {
    const action = try model.tryGetName(shape.id);
    _ = action; // autofix

    try body.expr(.{ .raw = "_ = self" });
    try body.expr(.{ .raw = "_ = input" });
    try body.prefix(.ret).expr(.{ .raw = "undefined" });
}

fn writeErrorShape(_: Allocator, script: *Script, _: *const SmithyModel, shape: GenerateHooks.ErrorShape) !void {
    _ = try script.variable(.{ .is_public = true }, .{
        .identifier = .{ .name = "source" },
        .type = .{ .raw = "ErrorSource" },
    }, Expr.val(shape.source));

    _ = try script.variable(.{ .is_public = true }, .{
        .identifier = .{ .name = "code" },
        .type = Expr.typ(u10),
    }, Expr.val(shape.code));

    _ = try script.variable(.{ .is_public = true }, .{
        .identifier = .{ .name = "retryable" },
    }, Expr.val(shape.retryable));
}

fn uniqueListType(arena: Allocator, item: Expr) !Expr {
    const args = try arena.alloc(Expr, 1);
    args[0] = item;
    return Expr.call("*const _aws_types.Set", args);
}

test {
    _ = trt_auth;
    _ = trt_cloudform;
    _ = trt_core;
    _ = trt_endpoint;
    _ = trt_gateway;
    _ = trt_iam;
    _ = trt_protocol;
}
