//! ```
//! my-service/
//! ├ README.md
//! ├ client.zig
//! ├ data_types.zig
//! ├ endpoint.zig
//! ├ operation/
//!   ├ my-op.zig
//! ```
const std = @import("std");
const Allocator = std.mem.Allocator;
const test_alloc = std.testing.allocator;
const jobz = @import("jobz");
const codmod = @import("codmod");
const md = codmod.md;
const zig = codmod.zig;
const files_jobs = @import("codmod/jobs").files;
const codegen_jobs = @import("codmod/jobs").codegen;
const clnt = @import("client.zig");
const ClientEndpoint = @import("client_endpoint.zig").ClientEndpoint;
const ClientOperationsDir = @import("client_operation.zig").ClientOperationsDir;
const cfg = @import("../config.zig");
const ScopeTag = @import("../pipeline.zig").ScopeTag;
const SymbolsProvider = @import("../systems/SymbolsProvider.zig");
const name_util = @import("../utils/names.zig");
const trt_docs = @import("../traits/docs.zig");
const trt_rules = @import("../traits/rules.zig");
const trt_auth = @import("../traits/auth.zig");
const AuthId = trt_auth.AuthId;
const TimestampFormat = @import("../traits/protocol.zig").TimestampFormat.Value;

pub const ScriptHeadHook = jobz.Task.Hook("Smithy Script Head", anyerror!void, &.{*zig.ContainerBuild});
pub const ServiceReadmeHook = codegen_jobs.MarkdownDoc.Hook("Smithy Readme Codegen", &.{ServiceReadmeMetadata});
pub const ServiceExtensionHook = jobz.Task.Hook("Smithy Service Extension", anyerror!void, &.{*ServiceExtension});

pub const ServiceExtension = struct {
    auth_schemes: std.ArrayList(trt_auth.AuthId),
    common_errors: std.ArrayList(SymbolsProvider.Error),
    timestamp_format: ?TimestampFormat = null,

    pub fn appendAuthScheme(self: *ServiceExtension, auth_id: AuthId) !void {
        try self.auth_schemes.append(auth_id);
    }

    pub fn appendError(self: *ServiceExtension, err: SymbolsProvider.Error) !void {
        try self.common_errors.append(err);
    }
};

pub const ServiceReadmeMetadata = struct {
    /// `{[slug]s}` service SDK ID
    slug: []const u8,
    /// `{[title]s}` service title
    title: []const u8,
    /// `{[intro]s}` introduction description
    intro: ?[]const u8,
};

pub const CodegenService = files_jobs.OpenDir.Task("Smithy Codegen Service", serviceCodegenTask, .{
    .injects = &.{SymbolsProvider},
});
fn serviceCodegenTask(self: *const jobz.Delegate, symbols: *SymbolsProvider) anyerror!void {
    if (self.hasOverride(ServiceReadmeHook)) {
        try self.evaluate(ServiceReadme, .{ "README.md", .{} });
    } else {
        std.log.warn("Skipped readme generation – missing `ServiceReadmeHook` overide.", .{});
    }

    try extendServiceSchemes(self, symbols);
    try self.evaluate(files_jobs.WriteFile.Chain(clnt.ServiceClient, .sync), .{ cfg.service_client_filename, .{} });

    if (symbols.hasTrait(symbols.service_id, trt_rules.EndpointRuleSet.id)) {
        try self.evaluate(files_jobs.WriteFile.Chain(ClientEndpoint, .sync), .{ cfg.endpoint_filename, .{} });
    }

    if (symbols.service_data_shapes.len > 0) {
        try self.evaluate(files_jobs.WriteFile.Chain(clnt.ClientDataTypes, .sync), .{ cfg.types_filename, .{} });
    }

    if (symbols.service_operations.len > 0) {
        try self.evaluate(ClientOperationsDir, .{ cfg.dir_operations, .{ .create_on_not_found = true } });
    }
}

fn extendServiceSchemes(self: *const jobz.Delegate, symbols: *SymbolsProvider) !void {
    std.debug.assert(symbols.service_errors.len == 0);
    std.debug.assert(symbols.service_auth_schemes.len == 0);

    const sid = symbols.service_id;
    const service = (try symbols.getShape(sid)).service;

    var extension = ServiceExtension{
        .auth_schemes = std.ArrayList(AuthId).init(self.alloc()),
        .common_errors = std.ArrayList(SymbolsProvider.Error).init(self.alloc()),
    };

    // Prefill common errors
    for (service.errors) |eid| try extension.appendError(try symbols.buildError(eid));

    // Prefill auth schemes
    if (symbols.hasTrait(sid, trt_auth.http_basic_id)) try extension.appendAuthScheme(.http_basic);
    if (symbols.hasTrait(sid, trt_auth.http_bearer_id)) try extension.appendAuthScheme(.http_bearer);
    if (symbols.hasTrait(sid, trt_auth.http_digest_id)) try extension.appendAuthScheme(.http_digest);
    if (symbols.hasTrait(sid, trt_auth.HttpApiKey.id)) try extension.appendAuthScheme(.http_api_key);

    // Extend
    if (self.hasOverride(ServiceExtensionHook)) try self.evaluate(ServiceExtensionHook, .{&extension});

    // Sort auth schemes
    std.mem.sort(AuthId, extension.auth_schemes.items, {}, struct {
        fn f(_: void, l: AuthId, r: AuthId) bool {
            return std.ascii.lessThanIgnoreCase(std.mem.asBytes(&l), std.mem.asBytes(&r));
        }
    }.f);

    symbols.service_errors = try extension.common_errors.toOwnedSlice();
    symbols.service_auth_schemes = try extension.auth_schemes.toOwnedSlice();
    if (extension.timestamp_format) |fmt| symbols.service_timestamp_fmt = fmt;
}

const ServiceReadme = files_jobs.WriteFile.Task("Service Readme Codegen", serviceReadmeTask, .{
    .injects = &.{SymbolsProvider},
});
fn serviceReadmeTask(self: *const jobz.Delegate, symbols: *SymbolsProvider, writer: std.io.AnyWriter) anyerror!void {
    const sid = symbols.service_id;
    const slug = self.readValue([]const u8, ScopeTag.slug) orelse return error.MissingSlug;
    const title = trt_docs.Title.get(symbols, sid) orelse try name_util.formatCase(self.alloc(), .title, slug);
    const intro: ?[]const u8 = if (trt_docs.Documentation.get(symbols, sid)) |src|
        try serviceReadmeWriteIntro(self.alloc(), src)
    else
        null;

    try self.evaluate(ServiceReadmeHook, .{ writer, ServiceReadmeMetadata{
        .slug = slug,
        .title = title,
        .intro = intro,
    } });
}

fn serviceReadmeWriteIntro(allocator: Allocator, source: []const u8) ![]const u8 {
    var build = try md.MutableDocument.init(allocator);
    try md.html.convert(allocator, build.root(), source, .{
        .codeblock_safety = true,
    });
    const markdown = try build.toReadOnly(allocator);
    defer markdown.deinit(allocator);

    var str = std.ArrayList(u8).init(allocator);
    errdefer str.deinit();

    var wrt = codmod.CodegenWriter.init(allocator, str.writer().any());
    defer wrt.deinit();

    try markdown.write(&wrt);
    return str.toOwnedSlice();
}

test ServiceReadme {
    const invoker = comptime blk: {
        var builder = jobz.InvokerBuilder{};

        _ = builder.Override(ServiceReadmeHook, "Test Readme", struct {
            fn f(_: *const jobz.Delegate, bld: md.ContainerAuthor, metadata: ServiceReadmeMetadata) anyerror!void {
                try bld.heading(2, metadata.title);
            }
        }.f, .{});

        break :blk builder.consume();
    };

    var tester = try jobz.PipelineTester.init(.{ .invoker = invoker });
    defer tester.deinit();

    _ = try tester.provideService(SymbolsProvider{ .arena = test_alloc }, struct {
        fn f(service: *SymbolsProvider, _: Allocator) void {
            service.deinit();
        }
    }.f);

    try tester.defineValue([]const u8, ScopeTag.slug, "foo_service");

    const output = try files_jobs.evaluateWriteFile(test_alloc, tester.pipeline, ServiceReadme, .{});
    defer test_alloc.free(output);
    try codegen_jobs.expectEqualMarkdownDoc("## Foo Service", output);
}

pub const ScriptCodegen = codegen_jobs.ZigScript.Abstract("Smithy Script Codegen", serviceScriptGenTask, .{
    .varyings = &.{*zig.ContainerBuild},
});
fn serviceScriptGenTask(
    self: *const jobz.Delegate,
    bld: *zig.ContainerBuild,
    task: jobz.AbstractEval(&.{*zig.ContainerBuild}, anyerror!void),
) anyerror!void {
    try bld.constant("std").assign(bld.x.import("std"));
    try bld.constant("Allocator").assign(bld.x.raw("std.mem.Allocator"));
    try bld.constant(cfg.runtime_scope).assign(bld.x.import("smithy"));

    if (self.hasOverride(ScriptHeadHook)) {
        try self.evaluate(ScriptHeadHook, .{bld});
    }

    try task.evaluate(.{bld});
}

pub fn expectServiceScript(
    comptime expected: []const u8,
    comptime task: jobz.Task,
    pipeline: *jobz.Pipeline,
    input: jobz.AbstractTask.ExtractChildInput(task),
) !void {
    const output = try codegen_jobs.evaluateZigScript(test_alloc, pipeline, task, input);
    defer test_alloc.free(output);
    try codegen_jobs.expectEqualZigScript(
        \\const std = @import("std");
        \\
        \\const Allocator = std.mem.Allocator;
        \\
        \\const smithy = @import("smithy");
        \\
        \\
    ++ expected, output);
}

test ScriptCodegen {
    const invoker = comptime blk: {
        var builder = jobz.InvokerBuilder{};

        _ = builder.Override(ScriptHeadHook, "Test Script Head", struct {
            fn f(_: *const jobz.Delegate, bld: *zig.ContainerBuild) anyerror!void {
                try bld.comment(.normal, "header");
            }
        }.f, .{});

        break :blk builder.consume();
    };

    var tester = try jobz.PipelineTester.init(.{ .invoker = invoker });
    defer tester.deinit();

    const TestScript = ScriptCodegen.Task("Test Script", struct {
        fn f(_: *const jobz.Delegate, bld: *zig.ContainerBuild) anyerror!void {
            try bld.constant("foo").assign(bld.x.raw("undefined"));
        }
    }.f, .{});

    try expectServiceScript(
        \\// header
        \\const foo = undefined;
    , TestScript, tester.pipeline, .{});
}
