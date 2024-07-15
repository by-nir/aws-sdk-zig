const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const pipez = @import("../pipeline/root.zig");
const Task = pipez.Task;
const Delegate = pipez.Delegate;
const AbstractTask = pipez.AbstractTask;
const AbstractEval = pipez.AbstractEval;
const syb = @import("../systems/symbols.zig");
const SmithyId = syb.SmithyId;
const SymbolsProvider = syb.SymbolsProvider;
const RulesEngine = @import("../systems/rules.zig").RulesEngine;
const md = @import("../codegen/md.zig");
const zig = @import("../codegen/zig.zig");
const Writer = @import("../codegen/CodegenWriter.zig");
const name_util = @import("../utils/names.zig");
const IssuesBag = @import("../utils/IssuesBag.zig");
const files_tasks = @import("files.zig");
const codegen_tasks = @import("codegen.zig");
const ScopeTag = @import("smithy.zig").ScopeTag;
const shape_tasks = @import("smithy_codegen_shape.zig");
const trt_docs = @import("../traits/docs.zig");
const trt_rules = @import("../traits/rules.zig");
const test_symbols = @import("../testing/symbols.zig");

pub const ScriptHeadHook = Task.Hook("Smithy Script Head", anyerror!void, &.{*zig.ContainerBuild});
pub const ServiceReadmeHook = codegen_tasks.MarkdownDoc.Hook("Smithy Readme Codegen", &.{ReadmeMetadata});
pub const ClientScriptHeadHook = Task.Hook("Smithy Client Script Head", anyerror!void, &.{*zig.ContainerBuild});
pub const EndpointScriptHeadHook = Task.Hook("Smithy Endpoint Script Head", anyerror!void, &.{*zig.ContainerBuild});

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

pub const ServiceCodegen = files_tasks.OpenDir.Task("Smithy Service Codegen", serviceCodegenTask, .{
    .injects = &.{SymbolsProvider},
});
fn serviceCodegenTask(self: *const Delegate, symbols: *SymbolsProvider) anyerror!void {
    try self.evaluate(files_tasks.WriteFile.Chain(ServiceClient, .sync), .{ "client.zig", .{} });

    try self.evaluate(files_tasks.WriteFile.Chain(ServiceErrors, .sync), .{ "errors.zig", .{} });

    if (symbols.hasTrait(symbols.service_id, trt_rules.EndpointRuleSet.id)) {
        try self.evaluate(files_tasks.WriteFile.Chain(ServiceEndpoint, .sync), .{ "endpoint.zig", .{} });
    }

    const resources_ids = blk: {
        const service = (try symbols.getShape(symbols.service_id)).service;
        break :blk service.resources;
    };
    for (resources_ids) |id| {
        const filename = try resourceFilename(self.alloc(), symbols, id);
        try self.evaluate(files_tasks.WriteFile.Chain(ServiceResource, .sync), .{ filename, .{}, id });
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

    try bld.constant("service_errors").assign(bld.x.import("errors.zig"));

    if (symbols.hasTrait(symbols.service_id, trt_rules.EndpointRuleSet.id)) {
        try testables.append("service_endpoint");
        try bld.constant("service_endpoint").assign(bld.x.import("endpoint.zig"));
    }

    const service = (try symbols.getShape(symbols.service_id)).service;
    for (service.resources) |id| {
        const filename = try resourceFilename(self.alloc(), symbols, id);
        const field_name = filename[0 .. filename.len - ".zig".len];
        try testables.append(field_name);
        try bld.constant(field_name).assign(bld.x.import(filename));
    }

    if (self.hasOverride(ClientScriptHeadHook)) {
        try self.evaluate(ClientScriptHeadHook, .{bld});
    }

    try symbols.enqueue(symbols.service_id);
    while (symbols.next()) |id| {
        try self.evaluate(shape_tasks.WriteShape, .{ bld, id });
    }

    try bld.testBlockWith(null, testables.items, struct {
        fn f(ctx: []const []const u8, b: *zig.BlockBuild) !void {
            try b.discard().id("service_errors").end();
            for (ctx) |testable| try b.discard().id(testable).end();
        }
    }.f);
}

test "ServiceClient" {
    var tester = try pipez.PipelineTester.init(.{ .invoker = shape_tasks.TEST_INVOKER });
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
        \\const service_errors = @import("errors.zig");
        \\
        \\const service_endpoint = @import("endpoint.zig");
        \\
        \\const resource_resource = @import("resource_resource.zig");
        \\
        \\/// Some _service_...
        \\pub const Service = struct {
        \\    pub fn operation(self: @This(), input: OperationInput) smithy.Result(OperationOutput, service_errors.OperationErrors) {
        \\        return undefined;
        \\    }
        \\};
        \\
        \\pub const OperationInput = struct {};
        \\
        \\pub const OperationOutput = struct {};
        \\
        \\test {
        \\    _ = service_errors;
        \\
        \\    _ = service_endpoint;
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
    try bld.constant("service_errors").assign(bld.x.import("errors.zig"));

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
    var tester = try pipez.PipelineTester.init(.{ .invoker = shape_tasks.TEST_INVOKER });
    defer tester.deinit();

    var issues = IssuesBag.init(test_alloc);
    defer issues.deinit();
    _ = try tester.provideService(&issues, null);

    var symbols = try test_symbols.setup(tester.alloc(), &.{.service});
    defer symbols.deinit();
    _ = try tester.provideService(&symbols, null);

    try expectServiceScript(
        \\const service_errors = @import("errors.zig");
        \\
        \\pub const Resource = struct {
        \\    forecast_id: []const u8,
        \\
        \\    pub fn operation(self: @This(), input: OperationInput) smithy.Result(OperationOutput, service_errors.OperationErrors) {
        \\        return undefined;
        \\    }
        \\};
        \\
        \\pub const OperationInput = struct {};
        \\
        \\pub const OperationOutput = struct {};
    , ServiceResource, tester.pipeline, .{SmithyId.of("test.serve#Resource")});
}

const ServiceErrors = ServiceScriptGen.Task("Smithy Service Errors Codegen", serviceErrorsTask, .{
    .injects = &.{SymbolsProvider},
});
fn serviceErrorsTask(
    self: *const Delegate,
    symbols: *SymbolsProvider,
    bld: *zig.ContainerBuild,
) anyerror!void {
    var errors = std.AutoArrayHashMap(SmithyId, void).init(self.alloc());

    const service = (try symbols.getShape(symbols.service_id)).service;
    for (service.errors) |id| try errors.put(id, {});

    for (service.operations) |op_id| {
        try processOperationErrors(self, symbols, bld, &errors, op_id, service.errors);
    }

    for (service.resources) |rsc_id| {
        try processResourceErrors(self, symbols, bld, &errors, rsc_id, service.errors);
    }

    var it = errors.iterator();
    while (it.next()) |id| {
        try self.evaluate(shape_tasks.WriteErrorShape, .{ bld, id.key_ptr.* });
    }
}

fn processResourceErrors(
    self: *const Delegate,
    symbols: *SymbolsProvider,
    bld: *zig.ContainerBuild,
    queue: *std.AutoArrayHashMap(SmithyId, void),
    rsc_id: SmithyId,
    common_errors: []const SmithyId,
) !void {
    const resource = (try symbols.getShape(rsc_id)).resource;

    for (resource.operations) |op_id| {
        try processOperationErrors(self, symbols, bld, queue, op_id, common_errors);
    }

    for (resource.collection_ops) |op_id| {
        try processOperationErrors(self, symbols, bld, queue, op_id, common_errors);
    }

    for (resource.resources) |sub_id| {
        try processResourceErrors(self, symbols, bld, queue, sub_id, common_errors);
    }
}

fn processOperationErrors(
    self: *const Delegate,
    symbols: *SymbolsProvider,
    bld: *zig.ContainerBuild,
    queue: *std.AutoArrayHashMap(SmithyId, void),
    op_id: SmithyId,
    common_errors: []const SmithyId,
) !void {
    const operation = (try symbols.getShape(op_id)).operation;
    for (operation.errors) |err_id| try queue.put(err_id, {});
    if (operation.errors.len + common_errors.len > 0) {
        try self.evaluate(shape_tasks.WriteErrorSet, .{ bld, op_id, operation.errors, common_errors });
    }
}

test "ServiceErrors" {
    var tester = try pipez.PipelineTester.init(.{ .invoker = shape_tasks.TEST_INVOKER });
    defer tester.deinit();

    var issues = IssuesBag.init(test_alloc);
    defer issues.deinit();
    _ = try tester.provideService(&issues, null);

    var symbols = try test_symbols.setup(tester.alloc(), &.{ .service, .err });
    defer symbols.deinit();
    _ = try tester.provideService(&symbols, null);

    symbols.service_id = SmithyId.of("test.serve#Service");
    try expectServiceScript(
        \\pub const OperationErrors = union(enum) {
        \\    service: ServiceError,
        \\    not_found: NotFound,
        \\};
        \\
        \\pub const OperationErrors = union(enum) {
        \\    service: ServiceError,
        \\    not_found: NotFound,
        \\};
        \\
        \\pub const ServiceError = struct {
        \\    pub const source: smithy.ErrorSource = .client;
        \\
        \\    pub const code: u10 = 429;
        \\
        \\    pub const retryable = true;
        \\};
        \\
        \\pub const NotFound = struct {
        \\    pub const source: smithy.ErrorSource = .server;
        \\
        \\    pub const code: u10 = 500;
        \\
        \\    pub const retryable = false;
        \\};
    , ServiceErrors, tester.pipeline, .{});
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

    if (self.hasOverride(EndpointScriptHeadHook)) {
        try self.evaluate(EndpointScriptHeadHook, .{bld});
    }

    try bld.constant("IS_TEST").assign(bld.x.import("builtin").dot().id("is_test"));

    const func_name = "resolve";
    const config_type = "EndpointConfig";
    var rulesgen = try rules_engine.getGenerator(self.alloc(), rule_set.parameters);

    const context = .{ .alloc = self.alloc(), .rulesgen = &rulesgen };
    try bld.public().constant(config_type).assign(bld.x.@"struct"().bodyWith(context, struct {
        fn f(ctx: @TypeOf(context), b: *zig.ContainerBuild) !void {
            try ctx.rulesgen.generateParametersFields(b);
        }
    }.f));

    try rulesgen.generateResolver(bld, func_name, config_type, rule_set.rules);

    if (trt_rules.EndpointTests.get(symbols, symbols.service_id)) |cases| {
        try rulesgen.generateTests(bld, func_name, config_type, cases);
    }
}

test "ServiceEndpoint" {
    var tester = try pipez.PipelineTester.init(.{});
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
        \\pub fn resolve(allocator: Allocator, config: EndpointConfig) anyerror![]const u8 {
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

const ServiceReadme = files_tasks.WriteFile.Task("Service Readme Codegen", serviceReadmeTask, .{
    .injects = &.{SymbolsProvider},
});
fn serviceReadmeTask(
    self: *const Delegate,
    symbols: *SymbolsProvider,
    writer: std.io.AnyWriter,
) anyerror!void {
    const service_id = symbols.service_id;
    const slug = self.readValue([]const u8, ScopeTag.slug) orelse return error.MissingSlug;

    const title =
        trt_docs.Title.get(symbols, service_id) orelse
        try name_util.titleCase(self.alloc(), slug);

    const intro: ?[]const u8 = if (trt_docs.Documentation.get(symbols, service_id)) |src|
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
    var build = md.Document.Build{ .allocator = allocator };
    try md.html.convert(allocator, &build, source);
    const markdown = try build.consume();
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
        var builder = pipez.InvokerBuilder{};

        _ = builder.Override(ServiceReadmeHook, "Test Readme", struct {
            fn f(_: *const Delegate, bld: *md.Document.Build, metadata: ReadmeMetadata) anyerror!void {
                try bld.heading(2, metadata.title);
            }
        }.f, .{});

        break :blk builder.consume();
    };

    var tester = try pipez.PipelineTester.init(.{ .invoker = invoker });
    defer tester.deinit();

    _ = try tester.provideService(SymbolsProvider{ .arena = test_alloc }, struct {
        fn f(service: *SymbolsProvider, _: Allocator) void {
            service.deinit();
        }
    }.f);

    try tester.defineValue([]const u8, ScopeTag.slug, "foo_service");

    const output = try files_tasks.evaluateWriteFile(test_alloc, tester.pipeline, ServiceReadme, .{});
    defer test_alloc.free(output);
    try codegen_tasks.expectEqualMarkdownDoc("## Foo Service", output);
}

const ServiceScriptGen = codegen_tasks.ZigScript.Abstract(
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
    pipeline: *pipez.Pipeline,
    input: AbstractTask.ExtractChildInput(task),
) !void {
    const output = try codegen_tasks.evaluateZigScript(test_alloc, pipeline, task, input);
    defer test_alloc.free(output);
    try codegen_tasks.expectEqualZigScript(
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
        var builder = pipez.InvokerBuilder{};

        _ = builder.Override(ScriptHeadHook, "Test Script Head", struct {
            fn f(_: *const Delegate, bld: *zig.ContainerBuild) anyerror!void {
                try bld.comment(.normal, "header");
            }
        }.f, .{});

        break :blk builder.consume();
    };

    var tester = try pipez.PipelineTester.init(.{ .invoker = invoker });
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
