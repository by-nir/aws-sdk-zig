const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const allocPrint = std.fmt.allocPrint;
const smithy = @import("smithy");
const zig = smithy.codegen_zig;
const Pipeline = smithy.Pipeline;
const PipelineHooks = Pipeline.Hooks;
const SmithyService = smithy.SmithyService;
const GenerateHooks = smithy.GenerateHooks;
const SymbolsProvider = smithy.SymbolsProvider;
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
    symbols: *SymbolsProvider,
    src_meta: PipelineHooks.ReadmeMeta,
) !void {
    var meta = src_meta;
    if (trt_core.Service.get(symbols, symbols.service_id)) |service| {
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

fn writeScriptHead(arena: Allocator, bld: *zig.ContainerBuild, symbols: *SymbolsProvider) !void {
    try bld.constant("aws_types").assign(bld.x.import("aws-types"));
    try bld.constant("ErrorSource").assign(bld.x.raw("aws_types.ErrorSource"));
    try bld.constant("Failable").assign(bld.x.raw("aws_types.Failable"));

    try bld.constant("aws_runtime").assign(bld.x.import("aws-runtime"));
    try bld.constant("Runtime").assign(bld.x.raw("aws_runtime.Client"));
    try bld.constant("Signer").assign(bld.x.raw("aws_runtime.Signer"));
    try bld.constant("Endpoint").assign(bld.x.raw("aws_runtime.Endpoint"));

    const service = trt_core.Service.get(symbols, symbols.service_id) orelse {
        return error.MissingService;
    };
    const service_endpoint = service.endpoint_prefix orelse {
        return error.MissingServiceEndpoint;
    };

    try bld.constant("endpoint_config").assign(bld.x.structLiteral(null, &.{
        bld.x.raw(try allocPrint(arena, ".name = \"{s}\"", .{service_endpoint})),
    }));
}

fn writeServiceHead(
    arena: Allocator,
    bld: *zig.ContainerBuild,
    symbols: *SymbolsProvider,
    shape: *const SmithyService,
) !void {
    try bld.field("runtime").typing(bld.x.raw("*Runtime")).end();
    try bld.field("signer").typing(bld.x.raw("Signer")).end();
    try bld.field("endpoint").typing(bld.x.raw("Endpoint")).end();

    const Funcs = struct {
        fn init(b: *zig.BlockBuild) !void {
            try b.discard().raw("region").end();
            try b.discard().raw("auth").end();
            try b.constant("runtime").assign(b.x.raw("Runtime.retain()"));
            try b.constant("signer").assign(b.x.raw("undefined"));
            try b.constant("endpoint").assign(b.x.raw("undefined"));
            try b.returns().structLiteral(null, &.{
                b.x.raw(".runtime = runtime"),
                b.x.raw(".signer = signer"),
                b.x.raw(".endpoint = endpoint"),
            }).end();
        }

        fn deinit(b: *zig.BlockBuild) !void {
            try b.raw("self.runtime.release()");
            try b.raw("self.endpoint.deinit()");
        }
    };

    try bld.public().function("init").arg("region", null).arg("auth", null)
        .returns(bld.x.This()).body(Funcs.init);

    try bld.public().function("deinit").arg("self", bld.x.This()).body(Funcs.deinit);

    _ = arena; // autofix
    _ = symbols; // autofix
    _ = shape; // autofix
}

fn operationReturnType(
    arena: Allocator,
    _: *SymbolsProvider,
    shape: GenerateHooks.OperationShape,
) !?[]const u8 {
    return if (shape.errors_type) |errors|
        try std.fmt.allocPrint(arena, "Failable({s}, {s})", .{
            shape.output_type orelse "void",
            errors,
        })
    else
        shape.output_type;
}

fn writeOperationBody(
    _: Allocator,
    bld: *zig.BlockBuild,
    symbols: *SymbolsProvider,
    shape: GenerateHooks.OperationShape,
) !void {
    const action = try symbols.getShapeName(shape.id, .type);
    _ = action; // autofix

    try bld.discard().raw("self").end();
    try bld.discard().raw("input").end();
    try bld.returns().raw("undefined").end();
}

fn writeErrorShape(
    _: Allocator,
    bld: *zig.ContainerBuild,
    _: *SymbolsProvider,
    shape: GenerateHooks.ErrorShape,
) !void {
    try bld.public().constant("source").typing(bld.x.raw("ErrorSource"))
        .assign(bld.x.valueOf(shape.source));

    try bld.public().constant("code").typing(bld.x.typeOf(u10))
        .assign(bld.x.valueOf(shape.code));

    try bld.public().constant("retryable").assign(bld.x.valueOf(shape.retryable));
}

fn uniqueListType(arena: Allocator, item_type: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "*const _aws_types.Set({s})",
        .{item_type},
    );
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
