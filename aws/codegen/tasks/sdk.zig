const std = @import("std");
const smithy = @import("smithy");
const SmithyTask = smithy.SmithyTask;
const SmithyOptions = smithy.SmithyOptions;
const md = smithy.codegen_md;
const zig = smithy.codegen_zig;
const SmithyService = smithy.SmithyService;
const SymbolsProvider = smithy.SymbolsProvider;
const pipez = smithy.pipez;
const Task = pipez.Task;
const Delegate = pipez.Delegate;
const files_tasks = smithy.files_tasks;
const codegen_tasks = smithy.codegen_tasks;
const itg_iam = @import("../integrate/iam.zig");
const itg_auth = @import("../integrate/auth.zig");
const itg_core = @import("../integrate/core.zig");
const itg_rules = @import("../integrate/rules.zig");
const itg_gateway = @import("../integrate/gateway.zig");
const itg_endpoint = @import("../integrate/endpoints.zig");
const itg_protocol = @import("../integrate/protocols.zig");
const itg_cloudformation = @import("../integrate/cloudformation.zig");

const ScopeTag = enum {
    whitelist,
};

const CONFIG_TYPENAME = "Config";
const WhitelistMap = std.StringHashMapUnmanaged(void);

pub const Sdk = Task.Define("AWS SDK", sdkTask, .{});
fn sdkTask(
    self: *const Delegate,
    src_dir: std.fs.Dir,
    /// Names of services to generate.
    /// If empty, all services will be generated.
    /// Only a service that has a source model in the provided directory will be considered.
    whitelist: []const []const u8,
) anyerror!void {
    if (whitelist.len > 0) {
        var map = WhitelistMap{};
        try map.ensureUnusedCapacity(self.alloc(), @intCast(whitelist.len));
        for (whitelist) |filename| {
            map.putAssumeCapacity(filename, {});
        }

        try self.defineValue(*const WhitelistMap, ScopeTag.whitelist, &map);
    }

    try self.evaluate(SmithyTask, .{ src_dir, smithy_config });
}

const smithy_config = SmithyOptions{
    .policy_service = .{
        .process = .abort,
        .parse = .skip,
        .codegen = .skip,
    },
    .policy_parse = .{
        .property = .abort,
        .trait = .skip,
    },
    .policy_codegen = .{
        .unknown_shape = .abort,
        .invalid_root = .abort,
        .shape_codegen_fail = .abort,
    },
    .rules_builtins = itg_rules.std_builtins,
    .rules_funcs = itg_rules.std_functions,
    .traits = itg_auth.traits ++
        itg_cloudformation.traits ++
        itg_core.traits ++
        itg_endpoint.traits ++
        itg_gateway.traits ++
        itg_iam.traits ++
        itg_protocol.traits,
};

pub const pipeline_invoker = blk: {
    var builder = pipez.InvokerBuilder{};

    _ = builder.Override(smithy.ServiceFilterHook, "AWS Service Filter", filterSourceModelHook, .{});
    _ = builder.Override(smithy.ServiceReadmeHook, "AWS Service Readme", writeReadmeHook, .{
        .injects = &.{SymbolsProvider},
    });
    _ = builder.Override(smithy.ScriptHeadHook, "AWS Script Head", writeScriptHeadHook, .{});
    _ = builder.Override(smithy.ClientScriptHeadHook, "AWS Client Script Head", writeClientScriptHeadHook, .{});
    _ = builder.Override(smithy.ServiceHeadHook, "AWS Service Shape Head", writeServiceHeadHook, .{});
    _ = builder.Override(smithy.OperationShapeHook, "AWS Operation Shape", writeOperationShapeHook, .{
        .injects = &.{SymbolsProvider},
    });

    break :blk builder.consume();
};

fn filterSourceModelHook(self: *const Delegate, filename: []const u8) bool {
    if (std.mem.startsWith(u8, filename, "sdk-")) return false;

    if (self.readValue(*const WhitelistMap, ScopeTag.whitelist)) |map| {
        return map.contains(filename[0 .. filename.len - ".json".len]);
    } else {
        return true;
    }
}

fn writeReadmeHook(
    self: *const Delegate,
    symbols: *SymbolsProvider,
    bld: *md.Document.Build,
    src: smithy.ReadmeMetadata,
) anyerror!void {
    var meta = src;
    if (itg_core.Service.get(symbols, symbols.service_id)) |service| {
        if (std.mem.startsWith(u8, service.sdk_id, "AWS")) {
            meta.title = service.sdk_id;
        } else {
            meta.title = try std.fmt.allocPrint(self.alloc(), "AWS {s}", .{service.sdk_id});
        }
    }

    try bld.rawFmt(@embedFile("../template/README.head.md.template"), .{ .title = meta.title, .slug = meta.slug });
    if (src.intro) |intro| try bld.raw(intro);
    try bld.raw(@embedFile("../template/README.install.md.template"));
    try bld.rawFmt(@embedFile("../template/README.footer.md.template"), .{ .title = meta.title });
}

fn writeScriptHeadHook(_: *const Delegate, bld: *zig.ContainerBuild) anyerror!void {
    try bld.constant("aws_types").assign(bld.x.import("aws-types"));
    try bld.constant("aws_runtime").assign(bld.x.import("aws-runtime"));
}

fn writeClientScriptHeadHook(_: *const Delegate, bld: *zig.ContainerBuild) anyerror!void {
    try bld.constant("Runtime").assign(bld.x.raw("aws_runtime.Client"));
    try bld.constant("Signer").assign(bld.x.raw("aws_runtime.Signer"));
}

fn writeServiceHeadHook(_: *const Delegate, bld: *zig.ContainerBuild, _: *const SmithyService) anyerror!void {
    try bld.field("runtime").typing(bld.x.raw("*Runtime")).end();
    try bld.field("signer").typing(bld.x.raw("Signer")).end();

    try bld.public().function("init")
        .arg("region", null).arg("auth", null)
        .returns(bld.x.This())
        .body(writeServiceInit);

    try bld.public().function("deinit")
        .arg("self", bld.x.This())
        .body(writeServiceDeinit);
}

fn writeServiceInit(bld: *zig.BlockBuild) anyerror!void {
    try bld.discard().raw("region").end();
    try bld.discard().raw("auth").end();
    try bld.constant("runtime").assign(bld.x.raw("Runtime.retain()"));
    try bld.constant("signer").assign(bld.x.raw("undefined"));
    try bld.returns().structLiteral(null, &.{
        bld.x.structAssign("runtime", bld.x.id("runtime")),
        bld.x.structAssign("signer", bld.x.id("signer")),
    }).end();
}

fn writeServiceDeinit(bld: *zig.BlockBuild) anyerror!void {
    try bld.raw("self.runtime.release()");
}

fn writeOperationShapeHook(
    _: *const Delegate,
    symbols: *SymbolsProvider,
    bld: *zig.BlockBuild,
    shape: smithy.OperationShape,
) anyerror!void {
    const action = try symbols.getShapeName(shape.id, .type);
    _ = action; // autofix

    try bld.discard().raw("self").end();
    try bld.discard().raw("input").end();
    try bld.returns().raw("undefined").end();
}
