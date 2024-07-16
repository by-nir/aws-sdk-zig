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
const name_util = smithy.name_util;
const files_tasks = smithy.files_tasks;
const codegen_tasks = smithy.codegen_tasks;
const BuiltInId = smithy.RulesBuiltIn.Id;
const trt_rule_set_id = smithy.traits.rules.EndpointRuleSet.id;
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

pub const Sdk = Task.Define("AWS SDK Client", sdkTask, .{});
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
    _ = builder.Override(smithy.ExtendClientScriptHook, "AWS Client Script Head", extendClientScriptHook, .{});
    _ = builder.Override(smithy.ExtendEndpointScriptHook, "AWS Endpoint Script Head", extendEndpointScriptHook, .{
        .injects = &.{SymbolsProvider},
    });
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
    _: *const Delegate,
    symbols: *SymbolsProvider,
    bld: *md.Document.Build,
    src: smithy.ReadmeMetadata,
) anyerror!void {
    var meta = src;
    if (itg_core.Service.get(symbols, symbols.service_id)) |service| {
        const title = service.sdk_id;
        meta.title = if (std.mem.startsWith(u8, title, "AWS ")) title[4..title.len] else title;
    }

    try bld.rawFmt(@embedFile("../template/README.head.md.template"), .{ .title = meta.title, .slug = meta.slug });
    if (src.intro) |intro| try bld.raw(intro);
    try bld.raw(@embedFile("../template/README.install.md.template"));
    try bld.rawFmt(@embedFile("../template/README.footer.md.template"), .{ .title = meta.title });
}

fn writeScriptHeadHook(_: *const Delegate, bld: *zig.ContainerBuild) anyerror!void {
    try bld.constant("aws_runtime").assign(bld.x.import("aws-runtime"));
    try bld.constant("aws_internal").assign(bld.x.raw("aws_runtime.internal"));
}

fn extendClientScriptHook(_: *const Delegate, bld: *zig.ContainerBuild) anyerror!void {
    try bld.constant("Runtime").assign(bld.x.raw("aws_runtime.Client"));
    try bld.constant("Signer").assign(bld.x.raw("aws_runtime.Signer"));
}

const ENDPOINT_SRC_ARG = "source";

fn extendEndpointScriptHook(
    self: *const Delegate,
    symbols: *SymbolsProvider,
    bld: *zig.ContainerBuild,
) anyerror!void {
    const trait = symbols.getTrait(smithy.RuleSet, symbols.service_id, trt_rule_set_id) orelse unreachable;

    const context = .{ .arena = self.alloc(), .params = trait.parameters };
    try bld.public().function("extractConfig")
        .arg(ENDPOINT_SRC_ARG, null)
        .returns(bld.x.id("EndpointConfig")).bodyWith(context, struct {
        fn f(ctx: @TypeOf(context), b: *zig.BlockBuild) !void {
            try b.@"if"(b.x.raw("@typeInfo(@TypeOf(source)) != .Struct"))
                .body(b.x.raw("@compileError(\"Endpoint’s `extractConfig` expect a source of type struct.\")")).end();

            try b.variable("value").typing(b.x.id("EndpointConfig")).assign(b.x.raw(".{}"));

            for (ctx.params) |param| {
                const id = param.value.built_in orelse continue;
                const expr = try mapEndpointConfigBuiltin(b.x, id);
                const val_field = try name_util.snakeCase(ctx.arena, param.key);
                try b.id("value").dot().id(val_field).assign().fromExpr(expr).end();
            }

            try b.returns().id("value").end();
        }
    }.f);
}

/// Provides a mapping from an endpoint built-in to a config value.
fn mapEndpointConfigBuiltin(x: zig.ExprBuild, id: BuiltInId) !zig.Expr {
    if (id == BuiltInId.of("AWS::Region")) {
        return x.@"if"(x.id(ENDPOINT_SRC_ARG).dot().id("region"))
            .capture("r").body(x.raw("r.toCode()"))
            .@"else"().body(x.valueOf(null))
            .end().consume();
    } else {
        const field: []const u8 = switch (id) {
            // Smithy
            BuiltInId.endpoint => "endpoint_url",
            // AWS
            BuiltInId.of("AWS::Region") => unreachable,
            BuiltInId.of("AWS::UseFIPS") => "use_fips",
            BuiltInId.of("AWS::UseDualStack") => "use_dual_stack",
            // TODO: Remaining built-ins
            //  BuiltInId.of("AWS::Auth::AccountId")
            //  BuiltInId.of("AWS::Auth::AccountIdEndpointMode")
            //  BuiltInId.of("AWS::Auth::CredentialScope")
            //  BuiltInId.of("AWS::S3::Accelerate")
            //  BuiltInId.of("AWS::S3::DisableMultiRegionAccessPoints")
            //  BuiltInId.of("AWS::S3::ForcePathStyle")
            //  BuiltInId.of("AWS::S3::UseArnRegion")
            //  BuiltInId.of("AWS::S3::UseGlobalEndpoint")
            //  BuiltInId.of("AWS::S3Control::UseArnRegion")
            //  BuiltInId.of("AWS::STS::UseGlobalEndpoint")
            else => return error.UnresolvedEndpointBuiltIn,
        };
        return x.id(ENDPOINT_SRC_ARG).dot().raw(field).consume();
    }
}

fn writeServiceHeadHook(_: *const Delegate, bld: *zig.ContainerBuild, _: *const SmithyService) anyerror!void {
    try bld.field("sdk_config").typing(bld.x.raw("aws_runtime.SdkConfig")).end();
    try bld.field("endpoint_config").typing(bld.x.raw("service_endpoint.EndpointConfig")).end();

    try bld.public().function("init")
        .arg("config", bld.x.raw("aws_runtime.SdkConfig"))
        .returns(bld.x.raw("!Client"))
        .body(writeServiceInit);

    try bld.public().function("deinit")
        .arg("self", bld.x.This())
        .body(writeServiceDeinit);
}

fn writeServiceInit(bld: *zig.BlockBuild) anyerror!void {
    try bld.trys().id("config").dot().call("validate", &.{}).end();
    try bld.constant("endpoint_conf").assign(bld.x.call("service_endpoint.extractConfig", &.{bld.x.id("config")}));

    try bld.returns().structLiteral(null, &.{
        bld.x.structAssign("config_sdk", bld.x.id("config")),
        bld.x.structAssign("config_endpoint", bld.x.id("endpoint_conf")),
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
