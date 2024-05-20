const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const smithy = @import("smithy");
const Script = smithy.Script;
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

const options = @import("options");
const whitelist: []const []const u8 = options.filter;
const models_path: []const u8 = options.models_path;
const install_path: []const u8 = options.install_path;

fn filterSourceModel(filename: []const u8) bool {
    return !std.mem.startsWith(u8, filename, "sdk-");
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa_alloc = gpa.allocator();
    defer _ = gpa.deinit();

    var pipeline = try Pipeline.init(gpa_alloc, std.heap.page_allocator, .{
        .src_dir_absolute = models_path,
        .out_dir_relative = install_path,
        .parse_policy = .{ .property = .abort, .trait = .skip },
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
            try files.append(try std.fmt.allocPrint(gpa_alloc, "{s}.json", .{filename}));
        }
        _ = try pipeline.processFiles(files.items);
    }
}

fn writeReadme(output: std.io.AnyWriter, model: *const SmithyModel, src_meta: PipelineHooks.ReadmeMeta) !void {
    var meta = src_meta;
    var title_buff: [128]u8 = undefined;
    if (trt_core.Service.get(model, model.service)) |service| {
        if (std.mem.startsWith(u8, service.sdk_id, "AWS")) {
            meta.title = service.sdk_id;
        } else {
            const title_len = service.sdk_id.len;
            std.debug.assert(title_len + 4 < 128);
            @memcpy(title_buff[0..4], "AWS ");
            @memcpy(title_buff[4..][0..title_len], service.sdk_id);
            meta.title = title_buff[0 .. 4 + title_len];
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

fn writeScriptHead(arena: Allocator, script: *Script) !void {
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
}

fn uniqueListType(arena: Allocator, item: Script.Expr) !Script.Expr {
    const args = try arena.alloc(Script.Expr, 1);
    args[0] = item;
    return Script.Expr.call("*const _aws_types.Set", args);
}

fn writeErrorShape(_: Allocator, script: *Script, _: *const SmithyModel, shape: GenerateHooks.ErrorShape) !void {
    _ = try script.variable(.{ .is_public = true }, .{
        .identifier = .{ .name = "source" },
        .type = .{ .raw = "ErrorSource" },
    }, Script.Expr.val(shape.source));

    _ = try script.variable(.{ .is_public = true }, .{
        .identifier = .{ .name = "code" },
        .type = Script.Expr.typ(u10),
    }, Script.Expr.val(shape.code));

    _ = try script.variable(.{ .is_public = true }, .{
        .identifier = .{ .name = "retryable" },
    }, Script.Expr.val(shape.retryable));
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

fn operationReturnType(arena: Allocator, _: *const SmithyModel, shape: GenerateHooks.OperationShape) !?Script.Expr {
    return if (shape.errors_type) |errors| blk: {
        const args = try arena.alloc(Script.Expr, 2);
        args[0] = shape.output_type orelse Script.Expr.typ(void);
        args[1] = errors;
        break :blk Script.Expr.call("Failable", args);
    } else shape.output_type;
}

fn writeOperationBody(
    _: Allocator,
    body: *Script.Scope,
    model: *const SmithyModel,
    shape: GenerateHooks.OperationShape,
) !void {
    // TODO
    const action = try model.tryGetName(shape.id);
    _ = action; // autofix

    try body.expr(.{ .raw = "_ = self" });
    try body.expr(.{ .raw = "_ = input" });
    try body.prefix(.ret).expr(.{ .raw = "undefined" });
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
