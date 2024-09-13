const std = @import("std");
const jobz = @import("jobz");
const Task = jobz.Task;
const Delegate = jobz.Delegate;
const md = @import("razdaz").md;
const zig = @import("razdaz").zig;
const smithy = @import("smithy/codegen");
const SmithyPipeline = smithy.PipelineTask;
const SmithyOptions = smithy.PipelineOptions;
const SmithyService = smithy.SmithyService;
const SymbolsProvider = smithy.SymbolsProvider;
const aws_cfg = @import("../config.zig");
const itg_auth = @import("../integrate/auth.zig");
const itg_rules = @import("../integrate/rules.zig");
const itg_proto = @import("../integrate/protocols.zig");
const aws_traits = @import("../traits.zig").aws_traits;
const ServiceTrait = @import("../traits/core.zig").Service;

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

    try self.evaluate(SmithyPipeline, .{ src_dir, smithy_config });
}

const smithy_config = SmithyOptions{
    .traits = aws_traits,
    .rules_builtins = itg_rules.std_builtins,
    .rules_funcs = itg_rules.std_functions,
    .behavior_service = .{
        .process = .abort,
        .parse = .skip,
        .codegen = .skip,
    },
    .behavior_parse = .{
        .property = .abort,
        .trait = .skip,
    },
    .behavior_codegen = .{
        .unknown_shape = .abort,
        .invalid_root = .abort,
        .shape_codegen_fail = .abort,
    },
};

pub const pipeline_invoker = blk: {
    var builder = jobz.InvokerBuilder{};

    _ = builder.Override(smithy.PipelineServiceFilterHook, "AWS Service Filter", filterSourceModel, .{});
    _ = builder.Override(smithy.ServiceReadmeHook, "AWS Service Readme", writeReadmeFile, .{});
    _ = builder.Override(smithy.ServiceScriptHeadHook, "AWS Service Script Head", writeScriptHead, .{});
    _ = builder.Override(smithy.ServiceAuthSchemesHook, "AWS Service Auth Schemes", itg_auth.extendAuthSchemes, .{
        .injects = &.{SymbolsProvider},
    });
    _ = builder.Override(smithy.ClientScriptHeadHook, "AWS Client Script Head", writeClientScriptHead, .{});
    _ = builder.Override(smithy.ClientShapeHeadHook, "AWS Client Shape Head", writeClientShapeHead, .{
        .injects = &.{SymbolsProvider},
    });
    _ = builder.Override(smithy.ClientOperationFuncHook, "AWS Client Operation Func", writeOperationFunc, .{
        .injects = &.{SymbolsProvider},
    });
    _ = builder.Override(smithy.EndpointScriptHeadHook, "AWS Endpoint Script Head", writeEndpointScriptHead, .{
        .injects = &.{SymbolsProvider},
    });

    break :blk builder.consume();
};

fn filterSourceModel(self: *const Delegate, filename: []const u8) bool {
    if (std.mem.startsWith(u8, filename, "sdk-")) return false;

    if (self.readValue(*const WhitelistMap, ScopeTag.whitelist)) |map| {
        return map.contains(filename[0 .. filename.len - ".json".len]);
    } else {
        return true;
    }
}

fn writeReadmeFile(_: *const Delegate, bld: md.ContainerAuthor, m: smithy.ServiceReadmeMetadata) anyerror!void {
    var meta = m;
    if (std.mem.startsWith(u8, meta.title, "AWS ")) {
        meta.title = meta.title[4..meta.title.len];
    }

    try bld.rawFmt(@embedFile("../template/README.head.md.template"), .{ .title = meta.title, .slug = meta.slug });
    if (meta.intro) |intro| try bld.raw(intro);
    try bld.raw(@embedFile("../template/README.install.md.template"));
    try bld.rawFmt(@embedFile("../template/README.footer.md.template"), .{ .title = meta.title });
}

fn writeScriptHead(_: *const Delegate, bld: *zig.ContainerBuild) anyerror!void {
    try bld.constant(aws_cfg.scope_runtime).assign(bld.x.import("aws-runtime"));
    try bld.constant(aws_cfg.scope_private).assign(bld.x.id(aws_cfg.scope_runtime).dot().id("_private_"));
}

fn writeEndpointScriptHead(self: *const Delegate, symbols: *SymbolsProvider, bld: *zig.ContainerBuild) anyerror!void {
    const rules_tid = smithy.traits.rules.EndpointRuleSet.id;
    const trait = symbols.getTrait(smithy.RuleSet, symbols.service_id, rules_tid) orelse unreachable;

    const context = .{ .arena = self.alloc(), .params = trait.parameters };
    try bld.public().function("extractConfig")
        .arg("source", null)
        .returns(bld.x.id(aws_cfg.endpoint_config_type)).bodyWith(context, struct {
        fn f(ctx: @TypeOf(context), b: *zig.BlockBuild) !void {
            try b.@"if"(b.x.raw("@typeInfo(@TypeOf(source)) != .@\"struct\""))
                .body(b.x.raw("@compileError(\"Endpoint’s `extractConfig` expect a source of type struct.\")")).end();

            try b.variable("value").typing(b.x.id(aws_cfg.endpoint_config_type)).assign(b.x.raw(".{}"));

            for (ctx.params) |param| {
                const id = param.value.built_in orelse continue;
                const expr = try itg_rules.mapConfigBuiltins(b.x, id);
                const val_field = try smithy.name_util.snakeCase(ctx.arena, param.key);
                try b.id("value").dot().id(val_field).assign().fromExpr(expr).end();
            }

            try b.returns().id("value").end();
        }
    }.f);
}

fn writeClientScriptHead(_: *const Delegate, bld: *zig.ContainerBuild) anyerror!void {
    try bld.constant(aws_cfg.scope_auth).assign(bld.x.id(aws_cfg.scope_private).dot().id("auth"));
    try bld.constant(aws_cfg.scope_protocol).assign(bld.x.id(aws_cfg.scope_private).dot().id("protocol"));
}

fn writeClientShapeHead(_: *const Delegate, symbols: *SymbolsProvider, bld: *zig.ContainerBuild, shape: *const SmithyService) anyerror!void {
    const service = ServiceTrait.get(symbols, symbols.service_id) orelse return error.MissingServiceTrait;
    try bld.constant("service_code").assign(bld.x.valueOf(service.endpoint_prefix orelse return error.MissingServiceCode));
    try bld.constant("service_version").assign(bld.x.valueOf(shape.version orelse return error.MissingServiceApiVersion));
    try bld.constant("service_arn").typing(bld.x.typeOf(?[]const u8)).assign(bld.x.valueOf(service.arn_namespace orelse null));
    try bld.constant("service_cloudtrail").typing(bld.x.typeOf(?[]const u8)).assign(bld.x.valueOf(service.cloud_trail_source orelse null));

    try bld.field("config_sdk").typing(bld.x.id(aws_cfg.scope_private).dot().id("ClientConfig")).end();
    try bld.field("config_endpoint").typing(bld.x.raw("srvc_endpoint.EndpointConfig")).end();
    try bld.field("http").typing(bld.x.typePointer(true, bld.x.id(aws_cfg.scope_runtime).dot().id("HttpClient"))).end();
    try bld.field("TEMP_creds").typing(bld.x.id(aws_cfg.scope_runtime).dot().id("Credentials")).end();

    try bld.public().function("init")
        .arg("config", bld.x.id(aws_cfg.scope_runtime).dot().id("Config"))
        .returns(bld.x.raw("!" ++ aws_cfg.service_client_type))
        .body(writeServiceInit);

    try bld.public().function("deinit")
        .arg("self", bld.x.id(aws_cfg.service_client_type))
        .body(writeServiceDeinit);
}

fn writeServiceInit(bld: *zig.BlockBuild) anyerror!void {
    try bld.constant("client_cfg").assign(bld.x.trys().id(aws_cfg.scope_private).dot().raw("ClientConfig.resolve(config)"));

    try bld.returns().structLiteral(null, &.{
        bld.x.structAssign("config_sdk", bld.x.id("client_cfg")),
        bld.x.structAssign("config_endpoint", bld.x.call("srvc_endpoint.extractConfig", &.{bld.x.id("client_cfg")})),
        bld.x.structAssign("http", bld.x.raw("client_cfg.http_client")),
        bld.x.structAssign("TEMP_creds", bld.x.raw("client_cfg.credentials")),
    }).end();
}

fn writeServiceDeinit(bld: *zig.BlockBuild) anyerror!void {
    try bld.raw("self.http.deinit()");
}

fn writeOperationFunc(self: *const Delegate, symbols: *SymbolsProvider, bld: *zig.BlockBuild, func: smithy.OperationFunc) anyerror!void {
    const alloc_expr = bld.x.id(aws_cfg.alloc_param);

    try bld.constant("endpoint").assign(bld.x.trys().call("srvc_endpoint.resolve", &.{
        alloc_expr,
        bld.x.raw("self.config_endpoint"),
    }));
    try bld.defers(bld.x.id("endpoint").dot().call("deinit", &.{alloc_expr}));

    const protocol: itg_proto.Protocol = .json_10;

    try bld.variable(aws_cfg.send_op_param).assign(bld.x.trys().id(aws_cfg.scope_private).dot().call(
        "ClientOperation.init",
        &.{
            alloc_expr,
            bld.x.valueOf(itg_proto.defaultHttpMethod(protocol)),
            bld.x.raw("std.Uri.parse(endpoint.url) catch unreachable"),
            bld.x.raw("self.config_sdk.app_id"),
            bld.x.valueOf(null), // TODO: trace_id
        },
    ));
    try bld.defers(bld.x.id(aws_cfg.send_op_param).dot().call("deinit", &.{}));

    try itg_proto.writeOperationRequest(self.alloc(), symbols, bld, func, protocol);
    if (func.auth_schemes.len > 0) try itg_auth.writeOperationAuth(self.alloc(), symbols, bld, func);
    try bld.trys().call("self.http.sendSync", &.{bld.x.id(aws_cfg.send_op_param)}).end();
    try itg_proto.writeOperationResponse(self.alloc(), symbols, bld, func, protocol);
}
