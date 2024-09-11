const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const jobz = @import("jobz");
const Task = jobz.Task;
const Delegate = jobz.Delegate;
const AbstractTask = jobz.AbstractTask;
const AbstractEval = jobz.AbstractEval;
const razdaz = @import("razdaz");
const md = razdaz.md;
const zig = razdaz.zig;
const Writer = razdaz.CodegenWriter;
const files_jobs = @import("razdaz/jobs").files;
const codegen_jobs = @import("razdaz/jobs").codegen;
const syb = @import("../systems/symbols.zig");
const SmithyId = syb.SmithyId;
const SymbolsProvider = syb.SymbolsProvider;
const cfg = @import("../config.zig");
const name_util = @import("../utils/names.zig");
const IssuesBag = @import("../utils/IssuesBag.zig");
const ScopeTag = @import("smithy.zig").ScopeTag;
const shape_tasks = @import("smithy_codegen_shape.zig");
const RulesEngine = @import("../systems/rules.zig").RulesEngine;
const trt_docs = @import("../traits/docs.zig");
const trt_rules = @import("../traits/rules.zig");
const test_symbols = @import("../testing/symbols.zig");

pub const ScriptHeadHook = Task.Hook("Smithy Script Head", anyerror!void, &.{*zig.ContainerBuild});
pub const ServiceReadmeHook = codegen_jobs.MarkdownDoc.Hook("Smithy Readme Codegen", &.{ReadmeMetadata});
pub const ExtendClientScriptHook = Task.Hook("Smithy Extend Client Script", anyerror!void, &.{*zig.ContainerBuild});
pub const ExtendEndpointScriptHook = Task.Hook("Smithy Extend Endpoint Script", anyerror!void, &.{*zig.ContainerBuild});

pub const ReadmeMetadata = struct {
    /// `{[slug]s}` service SDK ID
    slug: []const u8,
    /// `{[title]s}` service title
    title: []const u8,
    /// `{[intro]s}` introduction description
    intro: ?[]const u8,
};

pub const CodegenPolicy = struct {
    unknown_shape: IssuesBag.PolicyResolution = .abort,
    invalid_root: IssuesBag.PolicyResolution = .abort,
    shape_codegen_fail: IssuesBag.PolicyResolution = .abort,
};

pub const ServiceCodegen = files_jobs.OpenDir.Task("Smithy Service Codegen", serviceCodegenTask, .{
    .injects = &.{SymbolsProvider},
});
fn serviceCodegenTask(self: *const Delegate, symbols: *SymbolsProvider) anyerror!void {
    try self.evaluate(files_jobs.WriteFile.Chain(ServiceClient, .sync), .{ "client.zig", .{} });

    try self.evaluate(files_jobs.WriteFile.Chain(ServiceErrors, .sync), .{ "errors.zig", .{} });

    if (symbols.hasTrait(symbols.service_id, trt_rules.EndpointRuleSet.id)) {
        try self.evaluate(files_jobs.WriteFile.Chain(ServiceEndpoint, .sync), .{ "endpoint.zig", .{} });
    }

    const resources_ids = blk: {
        const service = (try symbols.getShape(symbols.service_id)).service;
        break :blk service.resources;
    };
    for (resources_ids) |id| {
        const filename = try resourceFilename(self.alloc(), symbols, id);
        try self.evaluate(files_jobs.WriteFile.Chain(ServiceResource, .sync), .{ filename, .{}, id });
    }

    if (self.hasOverride(ServiceReadmeHook)) {
        try self.evaluate(ServiceReadme, .{ "README.md", .{} });
    } else {
        std.log.warn("Skipped readme generation – missing `ServiceReadmeHook` overide.", .{});
    }
}

const ServiceClient = ServiceScriptGen.Task("Smithy Service Client Codegen", serviceClientTask, .{
    .injects = &.{SymbolsProvider},
});
fn serviceClientTask(
    self: *const Delegate,
    symbols: *SymbolsProvider,
    bld: *zig.ContainerBuild,
) anyerror!void {
    var testables = std.ArrayList([]const u8).init(self.alloc());

    try bld.constant("srvc_errors").assign(bld.x.import("errors.zig"));

    if (symbols.hasTrait(symbols.service_id, trt_rules.EndpointRuleSet.id)) {
        try testables.append("srvc_endpoint");
        try bld.constant("srvc_endpoint").assign(bld.x.import("endpoint.zig"));
    }

    const service = (try symbols.getShape(symbols.service_id)).service;
    for (service.resources) |id| {
        const filename = try resourceFilename(self.alloc(), symbols, id);
        const field_name = filename[0 .. filename.len - ".zig".len];
        try testables.append(field_name);
        try bld.constant(field_name).assign(bld.x.import(filename));
    }

    if (self.hasOverride(ExtendClientScriptHook)) {
        try self.evaluate(ExtendClientScriptHook, .{bld});
    }

    try symbols.enqueue(symbols.service_id);
    while (symbols.next()) |id| {
        try self.evaluate(shape_tasks.WriteShape, .{ bld, id });
    }

    try bld.testBlockWith(null, testables.items, struct {
        fn f(ctx: []const []const u8, b: *zig.BlockBuild) !void {
            try b.discard().id("srvc_errors").end();
            for (ctx) |testable| try b.discard().id(testable).end();
        }
    }.f);
}

test "ServiceClient" {
    var tester = try jobz.PipelineTester.init(.{ .invoker = shape_tasks.TEST_INVOKER });
    defer tester.deinit();

    var issues = IssuesBag.init(test_alloc);
    defer issues.deinit();
    _ = try tester.provideService(&issues, null);

    var symbols = try test_symbols.setup(tester.alloc(), &.{.service});
    defer symbols.deinit();
    _ = try tester.provideService(&symbols, null);

    var rules_engine = try RulesEngine.init(test_alloc, &.{}, &.{});
    defer rules_engine.deinit(test_alloc);
    _ = try tester.provideService(&rules_engine, null);

    symbols.service_id = SmithyId.of("test.serve#Service");
    try expectServiceScript(
        \\const srvc_errors = @import("errors.zig");
        \\
        \\const srvc_endpoint = @import("endpoint.zig");
        \\
        \\const resource_resource = @import("resource_resource.zig");
        \\
        \\/// Some _service_...
        \\pub const Client = struct {
        \\    pub fn operation(self: Client, allocator: Allocator, input: OperationInput) !smithy.Response(OperationOutput, srvc_errors.OperationError) {
        \\        return undefined;
        \\    }
        \\};
        \\
        \\pub const OperationInput = struct {
        \\    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        \\        try jw.beginObject();
        \\
        \\        try jw.endObject();
        \\    }
        \\};
        \\
        \\pub const OperationOutput = struct {
        \\    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        \\        try jw.beginObject();
        \\
        \\        try jw.endObject();
        \\    }
        \\};
        \\
        \\test {
        \\    _ = srvc_errors;
        \\
        \\    _ = srvc_endpoint;
        \\
        \\    _ = resource_resource;
        \\}
    , ServiceClient, tester.pipeline, .{});
}

const ServiceResource = ServiceScriptGen.Task("Smithy Service Resource Codegen", serviceResourceTask, .{
    .injects = &.{SymbolsProvider},
});
fn serviceResourceTask(
    self: *const Delegate,
    symbols: *SymbolsProvider,
    bld: *zig.ContainerBuild,
    resource_id: SmithyId,
) anyerror!void {
    try bld.constant("srvc_errors").assign(bld.x.import("errors.zig"));

    try symbols.enqueue(resource_id);
    while (symbols.next()) |id| {
        try self.evaluate(shape_tasks.WriteShape, .{ bld, id });
    }
}

fn resourceFilename(allocator: Allocator, symbols: *SymbolsProvider, id: SmithyId) ![]const u8 {
    const shape_name = try symbols.getShapeNameRaw(id);
    return try std.fmt.allocPrint(allocator, "resource_{s}.zig", .{name_util.SnakeCase{ .value = shape_name }});
}

test "ServiceResource" {
    var tester = try jobz.PipelineTester.init(.{ .invoker = shape_tasks.TEST_INVOKER });
    defer tester.deinit();

    var issues = IssuesBag.init(test_alloc);
    defer issues.deinit();
    _ = try tester.provideService(&issues, null);

    var symbols = try test_symbols.setup(tester.alloc(), &.{.service});
    defer symbols.deinit();
    _ = try tester.provideService(&symbols, null);

    try expectServiceScript(
        \\const srvc_errors = @import("errors.zig");
        \\
        \\pub const Resource = struct {
        \\    forecast_id: []const u8,
        \\
        \\    pub fn operation(self: Client, allocator: Allocator, input: OperationInput) !smithy.Response(OperationOutput, srvc_errors.OperationError) {
        \\        return undefined;
        \\    }
        \\};
        \\
        \\pub const OperationInput = struct {
        \\    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        \\        try jw.beginObject();
        \\
        \\        try jw.endObject();
        \\    }
        \\};
        \\
        \\pub const OperationOutput = struct {
        \\    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        \\        try jw.beginObject();
        \\
        \\        try jw.endObject();
        \\    }
        \\};
    , ServiceResource, tester.pipeline, .{SmithyId.of("test.serve#Resource")});
}

const ServiceErrors = ServiceScriptGen.Task("Smithy Service Errors Codegen", serviceErrorsTask, .{
    .injects = &.{SymbolsProvider},
});
fn serviceErrorsTask(self: *const Delegate, symbols: *SymbolsProvider, bld: *zig.ContainerBuild) anyerror!void {
    const service = (try symbols.getShape(symbols.service_id)).service;

    for (service.operations) |op_id| {
        try processOperationErrors(self, symbols, bld, op_id, service.errors);
    }

    for (service.resources) |rsc_id| {
        try processResourceErrors(self, symbols, bld, rsc_id, service.errors);
    }
}

fn processResourceErrors(
    self: *const Delegate,
    symbols: *SymbolsProvider,
    bld: *zig.ContainerBuild,
    rsc_id: SmithyId,
    common_errors: []const SmithyId,
) !void {
    const resource = (try symbols.getShape(rsc_id)).resource;

    for (resource.operations) |op_id| {
        try processOperationErrors(self, symbols, bld, op_id, common_errors);
    }

    for (resource.collection_ops) |op_id| {
        try processOperationErrors(self, symbols, bld, op_id, common_errors);
    }

    for (resource.resources) |sub_id| {
        try processResourceErrors(self, symbols, bld, sub_id, common_errors);
    }
}

fn processOperationErrors(
    self: *const Delegate,
    symbols: *SymbolsProvider,
    bld: *zig.ContainerBuild,
    op_id: SmithyId,
    common_errors: []const SmithyId,
) !void {
    const operation = (try symbols.getShape(op_id)).operation;
    try self.evaluate(shape_tasks.WriteErrorSet, .{ bld, op_id, operation.errors, common_errors });
}

test "ServiceErrors" {
    var tester = try jobz.PipelineTester.init(.{ .invoker = shape_tasks.TEST_INVOKER });
    defer tester.deinit();

    var issues = IssuesBag.init(test_alloc);
    defer issues.deinit();
    _ = try tester.provideService(&issues, null);

    var symbols = try test_symbols.setup(tester.alloc(), &.{ .service, .err });
    defer symbols.deinit();
    _ = try tester.provideService(&symbols, null);

    symbols.service_id = SmithyId.of("test.serve#Service");

    const expected = shape_tasks.TEST_OPERATION_ERR ++ "\n\n" ++ shape_tasks.TEST_OPERATION_ERR;
    try expectServiceScript(expected, ServiceErrors, tester.pipeline, .{});
}

const ServiceEndpoint = ServiceScriptGen.Task("Smithy Service Endpoint Codegen", serviceEndpointTask, .{
    .injects = &.{ SymbolsProvider, RulesEngine },
});
fn serviceEndpointTask(
    self: *const Delegate,
    symbols: *SymbolsProvider,
    rules_engine: *RulesEngine,
    bld: *zig.ContainerBuild,
) anyerror!void {
    const rule_set = trt_rules.EndpointRuleSet.get(symbols, symbols.service_id) orelse {
        return error.MissingEndpointRuleSet;
    };

    try bld.constant("IS_TEST").assign(bld.x.import("builtin").dot().id("is_test"));

    if (self.hasOverride(ExtendEndpointScriptHook)) {
        try self.evaluate(ExtendEndpointScriptHook, .{bld});
    }

    var rulesgen = try rules_engine.getGenerator(self.alloc(), rule_set.parameters);

    const context = .{ .alloc = self.alloc(), .rulesgen = &rulesgen };
    try bld.public().constant(cfg.endpoint_config_type).assign(bld.x.@"struct"().bodyWith(context, struct {
        fn f(ctx: @TypeOf(context), b: *zig.ContainerBuild) !void {
            try ctx.rulesgen.generateParametersFields(b);
        }
    }.f));

    try rulesgen.generateResolver(bld, rule_set.rules);

    if (trt_rules.EndpointTests.get(symbols, symbols.service_id)) |cases| {
        try rulesgen.generateTests(bld, cases);
    }
}

test "ServiceEndpoint" {
    var tester = try jobz.PipelineTester.init(.{});
    defer tester.deinit();

    var issues = IssuesBag.init(test_alloc);
    defer issues.deinit();
    _ = try tester.provideService(&issues, null);

    var symbols = try test_symbols.setup(tester.alloc(), &.{.service});
    defer symbols.deinit();
    _ = try tester.provideService(&symbols, null);

    var rules_engine = try RulesEngine.init(test_alloc, &.{}, &.{});
    defer rules_engine.deinit(test_alloc);
    _ = try tester.provideService(&rules_engine, null);

    symbols.service_id = SmithyId.of("test.serve#Service");
    try expectServiceScript(
        \\const IS_TEST = @import("builtin").is_test;
        \\
        \\pub const EndpointConfig = struct {
        \\    foo: ?bool = null,
        \\};
        \\
        \\pub fn resolve(allocator: Allocator, config: EndpointConfig) !smithy._private_.Endpoint {
        \\    var local_buffer: [512]u8 = undefined;
        \\
        \\    var local_heap = std.heap.FixedBufferAllocator.init(&local_buffer);
        \\
        \\    const scratch_alloc = local_heap.allocator();
        \\
        \\    _ = scratch_alloc;
        \\
        \\    var did_pass = false;
        \\
        \\    if (!IS_TEST) std.log.err("baz", .{});
        \\
        \\    return error.ReachedErrorRule;
        \\}
        \\
        \\test "Foo" {
        \\    const config = EndpointConfig{};
        \\
        \\    const endpoint = resolve(std.testing.allocator, config);
        \\
        \\    try std.testing.expectError(error.ReachedErrorRule, endpoint);
        \\}
    , ServiceEndpoint, tester.pipeline, .{});
}

const ServiceReadme = files_jobs.WriteFile.Task("Service Readme Codegen", serviceReadmeTask, .{
    .injects = &.{SymbolsProvider},
});
fn serviceReadmeTask(self: *const Delegate, symbols: *SymbolsProvider, writer: std.io.AnyWriter) anyerror!void {
    const sid = symbols.service_id;
    const slug = self.readValue([]const u8, ScopeTag.slug) orelse return error.MissingSlug;
    const title = trt_docs.Title.get(symbols, sid) orelse try name_util.titleCase(self.alloc(), slug);
    const intro: ?[]const u8 = if (trt_docs.Documentation.get(symbols, sid)) |src|
        try processIntro(self.alloc(), src)
    else
        null;

    try self.evaluate(ServiceReadmeHook, .{ writer, ReadmeMetadata{
        .slug = slug,
        .title = title,
        .intro = intro,
    } });
}

fn processIntro(allocator: Allocator, source: []const u8) ![]const u8 {
    var build = try md.MutableDocument.init(allocator);
    try md.html.convert(allocator, build.root(), source);
    const markdown = try build.toReadOnly(allocator);
    defer markdown.deinit(allocator);

    var str = std.ArrayList(u8).init(allocator);
    errdefer str.deinit();

    var wrt = Writer.init(allocator, str.writer().any());
    defer wrt.deinit();

    try markdown.write(&wrt);
    return str.toOwnedSlice();
}

test "ServiceReadme" {
    const invoker = comptime blk: {
        var builder = jobz.InvokerBuilder{};

        _ = builder.Override(ServiceReadmeHook, "Test Readme", struct {
            fn f(_: *const Delegate, bld: md.ContainerAuthor, metadata: ReadmeMetadata) anyerror!void {
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

const ServiceScriptGen = codegen_jobs.ZigScript.Abstract(
    "Service Script Codegen",
    serviceScriptGenTask,
    .{ .varyings = &.{*zig.ContainerBuild} },
);
fn serviceScriptGenTask(
    self: *const Delegate,
    bld: *zig.ContainerBuild,
    task: AbstractEval(&.{*zig.ContainerBuild}, anyerror!void),
) anyerror!void {
    try bld.constant("std").assign(bld.x.import("std"));
    try bld.constant("Allocator").assign(bld.x.raw("std.mem.Allocator"));
    try bld.constant("smithy").assign(bld.x.import("smithy"));

    if (self.hasOverride(ScriptHeadHook)) {
        try self.evaluate(ScriptHeadHook, .{bld});
    }

    try task.evaluate(.{bld});
}

pub fn expectServiceScript(
    comptime expected: []const u8,
    comptime task: Task,
    pipeline: *jobz.Pipeline,
    input: AbstractTask.ExtractChildInput(task),
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

test "ServiceScriptGen" {
    const invoker = comptime blk: {
        var builder = jobz.InvokerBuilder{};

        _ = builder.Override(ScriptHeadHook, "Test Script Head", struct {
            fn f(_: *const Delegate, bld: *zig.ContainerBuild) anyerror!void {
                try bld.comment(.normal, "header");
            }
        }.f, .{});

        break :blk builder.consume();
    };

    var tester = try jobz.PipelineTester.init(.{ .invoker = invoker });
    defer tester.deinit();

    const TestScript = ServiceScriptGen.Task("Test Script", struct {
        fn f(_: *const Delegate, bld: *zig.ContainerBuild) anyerror!void {
            try bld.constant("foo").assign(bld.x.raw("undefined"));
        }
    }.f, .{});

    try expectServiceScript(
        \\// header
        \\const foo = undefined;
    , TestScript, tester.pipeline, .{});
}
