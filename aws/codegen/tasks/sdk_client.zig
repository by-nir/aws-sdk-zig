const std = @import("std");
const pipez = @import("pipez");
const Task = pipez.Task;
const Delegate = pipez.Delegate;
const cdgn = @import("codegen");
const md = cdgn.md;
const zig = cdgn.zig;
const smithy = @import("smithy");
const smithy_conf = smithy.config;
const SmithyTask = smithy.SmithyTask;
const SmithyOptions = smithy.SmithyOptions;
const SmithyService = smithy.SmithyService;
const SymbolsProvider = smithy.SymbolsProvider;
const name_util = smithy.name_util;
const files_tasks = smithy.files_tasks;
const codegen_tasks = smithy.codegen_tasks;
const BuiltInId = smithy.RulesBuiltIn.Id;
const trt_rules = smithy.traits.rules.EndpointRuleSet;
const itg_iam = @import("../integrate/iam.zig");
const itg_auth = @import("../integrate/auth.zig");
const itg_core = @import("../integrate/core.zig");
const itg_rules = @import("../integrate/rules.zig");
const itg_gateway = @import("../integrate/gateway.zig");
const itg_endpoint = @import("../integrate/endpoints.zig");
const itg_protocol = @import("../integrate/protocols.zig");
const itg_cloudformation = @import("../integrate/cloudformation.zig");

const CONFIG_TYPENAME = "Config";
const ScopeTag = enum { whitelist };
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
    _ = builder.Override(smithy.ExtendEndpointScriptHook, "AWS Endpoint Script Head", extendEndpointScriptHook, .{
        .injects = &.{SymbolsProvider},
    });

    _ = builder.Override(smithy.ServiceHeadHook, "AWS Service Shape Head", writeServiceHeadHook, .{
        .injects = &.{SymbolsProvider},
    });
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

fn writeReadmeHook(_: *const Delegate, symbols: *SymbolsProvider, bld: md.ContainerAuthor, src: smithy.ReadmeMetadata) anyerror!void {
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

fn extendEndpointScriptHook(self: *const Delegate, symbols: *SymbolsProvider, bld: *zig.ContainerBuild) anyerror!void {
    const trait = symbols.getTrait(smithy.RuleSet, symbols.service_id, trt_rules.id) orelse unreachable;

    const context = .{ .arena = self.alloc(), .params = trait.parameters };
    try bld.public().function("extractConfig")
        .arg("source", null)
        .returns(bld.x.id(smithy_conf.endpoint_config_type)).bodyWith(context, struct {
        fn f(ctx: @TypeOf(context), b: *zig.BlockBuild) !void {
            try b.@"if"(b.x.raw("@typeInfo(@TypeOf(source)) != .Struct"))
                .body(b.x.raw("@compileError(\"Endpoint’s `extractConfig` expect a source of type struct.\")")).end();

            try b.variable("value").typing(b.x.id(smithy_conf.endpoint_config_type)).assign(b.x.raw(".{}"));

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
        return x.@"if"(x.id("source").dot().id("region"))
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
        return x.id("source").dot().raw(field).consume();
    }
}

fn writeServiceHeadHook(_: *const Delegate, symbols: *SymbolsProvider, bld: *zig.ContainerBuild, shape: *const SmithyService) anyerror!void {
    const service = itg_core.Service.get(symbols, symbols.service_id) orelse return error.MissingServiceTrait;
    try bld.constant("service_code").assign(bld.x.valueOf(service.endpoint_prefix orelse return error.MissingServiceCode));
    try bld.constant("service_version").assign(bld.x.valueOf(shape.version orelse return error.MissingServiceApiVersion));
    try bld.constant("service_arn").typing(bld.x.typeOf(?[]const u8)).assign(bld.x.valueOf(service.arn_namespace orelse null));
    try bld.constant("service_cloudtrail").typing(bld.x.typeOf(?[]const u8)).assign(bld.x.valueOf(service.cloud_trail_source orelse null));

    try bld.field("config_sdk").typing(bld.x.raw("aws_runtime.SdkConfig")).end();
    try bld.field("config_endpoint").typing(bld.x.raw("srvc_endpoint.EndpointConfig")).end();
    try bld.field("signer").typing(bld.x.raw("aws_internal.Signer")).end();
    try bld.field("http").typing(bld.x.raw("*aws_internal.HttpClient")).end();

    const client_self = smithy_conf.service_client_name;

    try bld.public().function("init")
        .arg("config", bld.x.raw("aws_runtime.SdkConfig"))
        .returns(bld.x.raw("!" ++ client_self))
        .body(writeServiceInit);

    try bld.public().function("deinit")
        .arg("_", bld.x.id(client_self))
        .body(writeServiceDeinit);
}

fn writeServiceInit(bld: *zig.BlockBuild) anyerror!void {
    try bld.trys().id("config").dot().call("validate", &.{}).end();

    try bld.constant("signer").assign(bld.x.call("aws_internal.Signer.from", &.{bld.x.structLiteral(null, &.{
        bld.x.structAssign("access_id", bld.x.valueOf("undefined").deref()),
        bld.x.structAssign("access_secret", bld.x.valueOf("undefined").deref()),
    })}));

    try bld.returns().structLiteral(null, &.{
        bld.x.structAssign("config_sdk", bld.x.id("config")),
        bld.x.structAssign("config_endpoint", bld.x.call("srvc_endpoint.extractConfig", &.{bld.x.id("config")})),
        bld.x.structAssign("http", bld.x.raw("aws_internal.HttpClient.retain()")),
        bld.x.structAssign("signer", bld.x.id("signer")),
    }).end();
}

fn writeServiceDeinit(bld: *zig.BlockBuild) anyerror!void {
    try bld.raw("aws_internal.HttpClient.release()");
}

fn writeOperationShapeHook(self: *const Delegate, symbols: *SymbolsProvider, bld: *zig.BlockBuild, shape: smithy.OperationShape) anyerror!void {
    try bld.constant("endpoint").assign(bld.x.trys().id("srvc_endpoint").dot().call("resolve", &.{
        bld.x.id(smithy_conf.allocator_name),
        bld.x.raw("self.config_endpoint"),
    }));
    try bld.defers(bld.x.id("endpoint").dot().call("deinit", &.{
        bld.x.id(smithy_conf.allocator_name),
    }));

    try bld.constant("service").assign(bld.x.structLiteral(bld.x.raw("aws_internal.HttpService"), &.{
        bld.x.structAssign("name", bld.x.id("service_code")),
        bld.x.structAssign("version", bld.x.id("service_version")),
        bld.x.structAssign("endpoint", bld.x.raw("std.Uri.parse(endpoint.url) catch unreachable")),
        bld.x.structAssign("region", bld.x.raw("self.config_sdk.region.?")),
        bld.x.structAssign("app_id", bld.x.raw("self.config_sdk.app_id")),
    }));

    try bld.constant("event").assign(bld.x.call("aws_internal.HttpEvent.new", &.{
        bld.x.valueOf(null), // TODO: trace_id
    }));

    const payload = if (shape.input_type) |_| blk: {
        try bld.constant("payload").assign(bld.x.trys().call("std.json.stringifyAlloc", &.{
            bld.x.id(smithy_conf.allocator_name),
            bld.x.id("input"),
            bld.x.raw(".{}"),
        }));
        try bld.defers(bld.x.raw("allocator.free(payload)"));

        break :blk bld.x.structLiteral(null, &.{
            bld.x.structAssign("type", bld.x.dot().id("json_10")),
            bld.x.structAssign("content", bld.x.id("payload")),
        });
    } else bld.x.valueOf(null);

    try bld.variable("request").assign(bld.x.trys().call("aws_internal.HttpRequest.init", &.{
        bld.x.id(smithy_conf.allocator_name),
        if (shape.input_type != null) bld.x.raw(".POST") else bld.x.raw(".GET"),
        bld.x.valueOf("/"),
        payload,
    }));
    try bld.defers(bld.x.raw("request.deinit()"));

    try bld.trys().call("request.addHeader", &.{
        bld.x.valueOf("X-Amz-Target"),
        bld.x.valueOf(try std.fmt.allocPrint(self.alloc(), "{s}.{s}", .{
            try symbols.getShapeNameRaw(symbols.service_id),
            try symbols.getShapeNameRaw(shape.id),
        })),
    }).end();

    try bld.constant("response").assign(bld.x.trys().call("self.http.send", &.{
        bld.x.id(smithy_conf.allocator_name),
        bld.x.raw("self.signer"),
        bld.x.id("service"),
        bld.x.id("event"),
        bld.x.addressOf().id("request"),
    }));
    try bld.errorDefers().body(bld.x.raw("response.deinit()"));

    try bld.returns().raw("undefined").end();
}
