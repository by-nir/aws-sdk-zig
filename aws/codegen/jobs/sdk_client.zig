const std = @import("std");
const jobz = @import("jobz");
const Delegate = jobz.Delegate;
const md = @import("razdaz").md;
const zig = @import("razdaz").zig;
const smithy = @import("smithy/codegen");
const SmithyPipeline = smithy.PipelineTask;
const SmithyService = smithy.SmithyService;
const SmithyOptions = smithy.PipelineOptions;
const SymbolsProvider = smithy.SymbolsProvider;
const aws_cfg = @import("../config.zig");
const itg_auth = @import("../integrate/auth.zig");
const itg_rules = @import("../integrate/rules.zig");
const itg_errors = @import("../integrate/errors.zig");
const itg_proto = @import("../integrate/protocols.zig");
const aws_traits = @import("../traits.zig").aws_traits;
const ServiceTrait = @import("../traits/core.zig").Service;

const CONFIG_TYPENAME = "Config";
const ScopeTag = enum { whitelist };
const WhitelistMap = std.StringHashMapUnmanaged(void);

pub const Sdk = jobz.Task.Define("AWS SDK Client", sdkTask, .{});
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
        .parse = .abort,
        .codegen = .abort,
    },
    .behavior_parse = .{
        .property = .abort,
        .trait = .skip,
    },
};

pub const pipeline_invoker = blk: {
    var builder = jobz.InvokerBuilder{};

    _ = builder.Override(smithy.PipelineServiceFilterHook, "AWS Service Filter", filterSourceModel, .{});
    _ = builder.Override(smithy.ServiceReadmeHook, "AWS Service Readme", writeReadmeFile, .{});
    _ = builder.Override(smithy.ServiceScriptHeadHook, "AWS Service Script Head", writeScriptHead, .{});
    _ = builder.Override(smithy.ServiceExtensionHook, "AWS Service Extension", extendService, .{
        .injects = &.{SymbolsProvider},
    });
    _ = builder.Override(smithy.ClientScriptHeadHook, "AWS Client Script Head", writeClientScriptHead, .{});
    _ = builder.Override(smithy.ClientShapeHeadHook, "AWS Client Shape Head", writeClientShapeHead, .{
        .injects = &.{SymbolsProvider},
    });
    _ = builder.Override(smithy.ClientSendSyncFuncHook, "AWS Client Send Sync Func", writeSendSyncFunc, .{
        .injects = &.{SymbolsProvider},
    });
    _ = builder.Override(
        smithy.EndpointScriptHeadHook,
        "AWS Endpoint Script Head",
        itg_rules.writeEndpointScriptHead,
        .{ .injects = &.{SymbolsProvider} },
    );

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

fn extendService(self: *const Delegate, symbols: *SymbolsProvider, extension: *smithy.ServiceExtension) anyerror!void {
    const protocol = try itg_proto.resolveServiceProtocol(symbols);
    extension.timestamp_format = itg_proto.resolveTimestampFormat(protocol);
    try itg_auth.extendAuthSchemes(self, symbols, extension);
    try itg_errors.extendCommonErrors(self, symbols, extension);
}

fn writeClientScriptHead(_: *const Delegate, bld: *zig.ContainerBuild) anyerror!void {
    try bld.constant(aws_cfg.scope_auth).assign(bld.x.id(aws_cfg.scope_private).dot().id("auth"));
    try bld.constant(aws_cfg.scope_protocol).assign(bld.x.id(aws_cfg.scope_private).dot().id("protocol"));
}

fn writeClientShapeHead(
    _: *const Delegate,
    symbols: *SymbolsProvider,
    bld: *zig.ContainerBuild,
    shape: *const SmithyService,
) anyerror!void {
    const service = ServiceTrait.get(symbols, symbols.service_id) orelse return error.MissingServiceTrait;
    try bld.constant("service_code").assign(bld.x.valueOf(service.endpoint_prefix orelse return error.MissingServiceCode));
    try bld.constant("service_version").assign(bld.x.valueOf(shape.version orelse return error.MissingServiceApiVersion));
    try bld.constant("service_arn").typing(bld.x.typeOf(?[]const u8)).assign(bld.x.valueOf(service.arn_namespace orelse null));
    try bld.constant("service_cloudtrail").typing(bld.x.typeOf(?[]const u8)).assign(bld.x.valueOf(service.cloud_trail_source orelse null));

    try bld.field("config_sdk").typing(bld.x.id(aws_cfg.scope_private).dot().id("ClientConfig")).end();
    try bld.field("config_endpoint").typing(bld.x.raw(aws_cfg.endpoint_scope ++ ".EndpointConfig")).end();
    try bld.field("http").typing(bld.x.typePointer(true, bld.x.id(aws_cfg.scope_private).dot().id("HttpClient"))).end();
    try bld.field("identity").typing(bld.x.typePointer(true, bld.x.id(aws_cfg.scope_private).dot().id("IdentityManager"))).end();

    try bld.public().function("init")
        .arg("config", bld.x.id(aws_cfg.scope_runtime).dot().id("Config"))
        .returns(bld.x.raw("!" ++ aws_cfg.service_client_type))
        .body(writeServiceInit);

    try bld.public().function("deinit")
        .arg("self", bld.x.id(aws_cfg.service_client_type))
        .body(writeServiceDeinit);
}

fn writeServiceInit(bld: *zig.BlockBuild) anyerror!void {
    try bld.constant("client_cfg").assign(
        bld.x.trys().id(aws_cfg.scope_private).dot().raw("ClientConfig.resolveFrom(config)"),
    );

    try bld.returns().structLiteral(null, &.{
        bld.x.structAssign("config_sdk", bld.x.id("client_cfg")),
        bld.x.structAssign("config_endpoint", bld.x.call(
            aws_cfg.endpoint_scope ++ ".extractConfig",
            &.{bld.x.id("client_cfg")},
        )),
        bld.x.structAssign("http", bld.x.raw("client_cfg.http_client")),
        bld.x.structAssign("identity", bld.x.raw("client_cfg.identity_manager")),
    }).end();
}

fn writeServiceDeinit(bld: *zig.BlockBuild) anyerror!void {
    try bld.raw("self.http.deinit()");
    try bld.raw("self.identity.deinit()");
}

/// ### Operation Memory Management
///
/// The user provides an allocator (assummed GPA), we use it to init two arenas:
/// 1. Scratch arena for the lifetime of **processing** the request.
/// 2. Output arena for the output/error payload – user ownes the returned memory.
///
/// The `ClientOperation` is created using the scratch arena.
/// Components who participate in the processing of the request can allocate
/// memory from it, while safly assuming that memory will be freed on their behalf.
///
/// The protocol implementations can use both the scratch and the output arenas.
/// They are also responsible for passing the output arena alongside the result.
fn writeSendSyncFunc(self: *const Delegate, symbols: *SymbolsProvider, bld: *zig.BlockBuild) anyerror!void {
    try bld.@"if"(
        bld.x.id(aws_cfg.send_meta_param).dot().id("Input").op(.eql).typeOf(void)
            .op(.@"and").raw("self.config_sdk.input_validation"),
    ).body(
        bld.x.trys().id(aws_cfg.send_input_param).dot().call("validate", &.{}),
    ).end();

    try bld.variable("scratch_arena").assign(
        bld.x.call("std.heap.ArenaAllocator.init", &.{bld.x.id(aws_cfg.alloc_param)}),
    );
    try bld.constant(aws_cfg.scratch_alloc).assign(bld.x.id("scratch_arena").dot().call("allocator", &.{}));
    try bld.defers(bld.x.id("scratch_arena").dot().call("deinit", &.{}));

    try bld.constant("endpoint").assign(bld.x.trys().call(aws_cfg.endpoint_scope ++ ".resolve", &.{
        bld.x.id(aws_cfg.scratch_alloc),
        bld.x.raw("self.config_endpoint"),
    }));

    const protocol = try itg_proto.resolveServiceProtocol(symbols);
    const transport = try itg_proto.resolveServiceTransport(symbols, protocol);
    _ = transport;

    try bld.constant(aws_cfg.send_op_param).assign(bld.x.trys().id(aws_cfg.scope_private).dot().call(
        "ClientOperation.new",
        &.{
            bld.x.id(aws_cfg.scratch_alloc),
            bld.x.valueOf(itg_proto.resolveHttpMethod(protocol)),
            bld.x.raw("std.Uri.parse(endpoint.url) catch unreachable"),
            bld.x.raw("self.config_sdk.app_id"),
            bld.x.valueOf(null), // TODO: trace_id
        },
    ));

    try itg_proto.writeOperationRequest(self.alloc(), symbols, bld, protocol);
    try itg_auth.writeOperationAuth(self.alloc(), symbols, bld);
    try bld.trys().call("self.http.sendSync", &.{bld.x.id(aws_cfg.send_op_param)}).end();

    try bld.variable(aws_cfg.output_arena).assign(
        bld.x.call("std.heap.ArenaAllocator.init", &.{bld.x.id(aws_cfg.alloc_param)}),
    );
    try bld.errorDefers().body((bld.x.id(aws_cfg.output_arena).dot().call("deinit", &.{})));

    const result = try itg_proto.writeOperationResult(self.alloc(), symbols, bld, protocol);
    try bld.returns().buildExpr(result).end();
}
