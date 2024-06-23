const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const allocPrint = std.fmt.allocPrint;
const smithy = @import("smithy");
const zig = smithy.codegen_zig;
const Pipeline = smithy.Pipeline;
const RulesEngine = smithy.RulesEngine;
const SmithyService = smithy.SmithyService;
const GenerateHooks = smithy.GenerateHooks;
const SymbolsProvider = smithy.SymbolsProvider;
const trt_rules = smithy.traits.rules;
const itg_iam = @import("integrate/iam.zig");
const itg_auth = @import("integrate/auth.zig");
const itg_core = @import("integrate/core.zig");
const itg_rules = @import("integrate/rules.zig");
const itg_gateway = @import("integrate/gateway.zig");
const itg_endpoint = @import("integrate/endpoints.zig");
const itg_protocol = @import("integrate/protocols.zig");
const itg_cloudform = @import("integrate/cloudformation.zig");

const CONFIG_TYPE = "Config";

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
        .parse_policy = .{
            .property = .abort,
            .trait = .skip,
        },
        .codegen_policy = .{
            .unknown_shape = .abort,
            .invalid_root = .abort,
            .shape_codegen_fail = .abort,
        },
        .process_policy = .{
            .model = .abort,
            .readme = .abort,
        },
        .rules_builtins = itg_rules.std_builtins,
        .rules_funcs = itg_rules.std_functions,
    }, .{
        .writeReadme = writeReadme,
        .writeScriptHead = writeScriptHead,
        .uniqueListType = uniqueListType,
        .writeErrorShape = writeErrorShape,
        .writeServiceHead = writeServiceHead,
        .operationReturnType = operationReturnType,
        .writeOperationBody = writeOperationBody,
    });
    defer pipeline.deinit();

    try pipeline.registerTraits(itg_auth.traits);
    try pipeline.registerTraits(itg_cloudform.traits);
    try pipeline.registerTraits(itg_core.traits);
    try pipeline.registerTraits(itg_endpoint.traits);
    try pipeline.registerTraits(itg_gateway.traits);
    try pipeline.registerTraits(itg_iam.traits);
    try pipeline.registerTraits(itg_protocol.traits);

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
    src_meta: GenerateHooks.ReadmeMeta,
) !void {
    var meta = src_meta;
    if (itg_core.Service.get(symbols, symbols.service_id)) |service| {
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
    try bld.constant("resolvePartition").assign(bld.x.import("sdk-partitions").dot().id("resolve"));

    const service = itg_core.Service.get(symbols, symbols.service_id) orelse {
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
    rules_engine: *const RulesEngine,
    shape: *const SmithyService,
) !void {
    try bld.field("runtime").typing(bld.x.raw("*Runtime")).end();
    try bld.field("signer").typing(bld.x.raw("Signer")).end();
    try bld.field("endpoint").typing(bld.x.raw("Endpoint")).end();

    try bld.public().function("init")
        .arg("region", null).arg("auth", null)
        .returns(bld.x.This())
        .body(serviceInit);

    try bld.public().function("deinit")
        .arg("self", bld.x.This())
        .body(serviceDeinit);

    if (trt_rules.EndpointRuleSet.get(symbols, symbols.service_id)) |rule_set| {
        const context = .{ .arena = arena, .params = rule_set.parameters, .engine = rules_engine };
        try bld.public().constant(CONFIG_TYPE).assign(bld.x.@"struct"().bodyWith(context, struct {
            fn f(ctx: @TypeOf(context), b: *zig.ContainerBuild) !void {
                try ctx.engine.generateConfigFields(ctx.arena, b, ctx.params);
            }
        }.f));

        try rules_engine.generateFunction(arena, bld, "resolveEndpoint", CONFIG_TYPE, rule_set);
    }
}

fn serviceInit(bld: *zig.BlockBuild) !void {
    try bld.discard().raw("region").end();
    try bld.discard().raw("auth").end();
    try bld.constant("runtime").assign(bld.x.raw("Runtime.retain()"));
    try bld.constant("signer").assign(bld.x.raw("undefined"));
    try bld.constant("endpoint").assign(bld.x.raw("undefined"));
    try bld.returns().structLiteral(null, &.{
        bld.x.raw(".runtime = runtime"),
        bld.x.raw(".signer = signer"),
        bld.x.raw(".endpoint = endpoint"),
    }).end();
}

fn serviceDeinit(bld: *zig.BlockBuild) !void {
    try bld.raw("self.runtime.release()");
    try bld.raw("self.endpoint.deinit()");
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
    _ = itg_auth;
    _ = itg_cloudform;
    _ = itg_core;
    _ = itg_endpoint;
    _ = itg_gateway;
    _ = itg_iam;
    _ = itg_protocol;
    _ = itg_rules;
}
