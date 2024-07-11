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
const ContainerBuild = @import("../codegen/zig.zig").ContainerBuild;
const Writer = @import("../codegen/CodegenWriter.zig");
const name_util = @import("../utils/names.zig");
const IssuesBag = @import("../utils/IssuesBag.zig");
const files_tasks = @import("files.zig");
const codegen_tasks = @import("codegen.zig");
const ScopeTag = @import("smithy.zig").ScopeTag;
const WriteShape = @import("smithy_codegen_shape.zig").WriteShape;
const trt_docs = @import("../traits/docs.zig");
const trt_rules = @import("../traits/rules.zig");
const test_symbols = @import("../testing/symbols.zig");

pub const ScriptHeadHook = Task.Hook("Smithy Script Head", anyerror!void, &.{*ContainerBuild});
pub const ServiceReadmeHook = codegen_tasks.MarkdownDoc.Hook("Smithy Readme Codegen", &.{ReadmeMetadata});
pub const ClientScriptHeadHook = Task.Hook("Smithy Client Script Head", anyerror!void, &.{*ContainerBuild});

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

    if (symbols.hasTrait(symbols.service_id, trt_rules.EndpointRuleSet.id)) {
        try self.evaluate(files_tasks.WriteFile.Chain(ServiceEndpoint, .sync), .{ "endpoint.zig", .{} });
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
fn serviceClientTask(self: *const Delegate, symbols: *SymbolsProvider, bld: *ContainerBuild) anyerror!void {
    if (self.hasOverride(ClientScriptHeadHook)) {
        try self.evaluate(ClientScriptHeadHook, .{bld});
    }

    if (symbols.hasTrait(symbols.service_id, trt_rules.EndpointRuleSet.id)) {
        try bld.constant("service_endpoint").assign(bld.x.import("endpoint.zig"));
    }

    try symbols.enqueue(symbols.service_id);
    while (symbols.next()) |id| {
        try self.evaluate(WriteShape, .{ bld, id });
    }
}

test "ServiceClient" {
    var tester = try pipez.PipelineTester.init(.{});
    defer tester.deinit();

    var issues = IssuesBag.init(test_alloc);
    defer issues.deinit();
    _ = try tester.provideService(&issues, null);

    var symbols = try test_symbols.setup(test_alloc, &.{ .root_child, .rules });
    defer symbols.deinit();
    _ = try tester.provideService(&symbols, null);

    var rules_engine = try RulesEngine.init(test_alloc, &.{}, &.{});
    defer rules_engine.deinit(test_alloc);
    _ = try tester.provideService(&rules_engine, null);

    symbols.service_id = SmithyId.of("test#Root");
    try expectServiceScript(
        \\const service_endpoint = @import("endpoint.zig");
        \\
        \\pub const Root = []const Child;
        \\
        \\pub const Child = []const i32;
    , ServiceClient, tester.pipeline, .{});
}

const ServiceEndpoint = ServiceScriptGen.Task("Smithy Service Endpoint Codegen", serviceEndpointTask, .{
    .injects = &.{ SymbolsProvider, RulesEngine },
});
fn serviceEndpointTask(
    self: *const Delegate,
    symbols: *SymbolsProvider,
    rules_engine: *RulesEngine,
    bld: *ContainerBuild,
) anyerror!void {
    const rule_set = trt_rules.EndpointRuleSet.get(symbols, symbols.service_id) orelse {
        return error.MissingEndpointRuleSet;
    };

    try bld.constant("resolvePartition").assign(bld.x.import("sdk-partitions").dot().id("resolve"));

    const func_name = "resolve";
    const config_type = "EndpointConfig";
    const rulesgen = try rules_engine.getGenerator(self.alloc(), rule_set.parameters);

    const context = .{ .alloc = self.alloc(), .rulesgen = rulesgen };
    try bld.public().constant(config_type).assign(bld.x.@"struct"().bodyWith(context, struct {
        fn f(ctx: @TypeOf(context), b: *ContainerBuild) !void {
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

    var symbols = try test_symbols.setup(test_alloc, &.{ .root_child, .rules });
    defer symbols.deinit();
    _ = try tester.provideService(&symbols, null);

    var rules_engine = try RulesEngine.init(test_alloc, &.{}, &.{});
    defer rules_engine.deinit(test_alloc);
    _ = try tester.provideService(&rules_engine, null);

    symbols.service_id = SmithyId.of("test#Root");
    try expectServiceScript(
        \\const resolvePartition = @import("sdk-partitions").resolve;
        \\
        \\pub const EndpointConfig = struct {
        \\    foo: ?bool = null,
        \\};
        \\
        \\pub fn resolve(allocator: Allocator, config: EndpointConfig) anyerror![]const u8 {
        \\    var did_pass = false;
        \\
        \\    std.log.err("baz", .{});
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
    .{ .varyings = &.{*ContainerBuild} },
);
fn serviceScriptGenTask(
    self: *const Delegate,
    bld: *ContainerBuild,
    task: AbstractEval(&.{*ContainerBuild}, anyerror!void),
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
            fn f(_: *const Delegate, bld: *ContainerBuild) anyerror!void {
                try bld.comment(.normal, "header");
            }
        }.f, .{});

        break :blk builder.consume();
    };

    var tester = try pipez.PipelineTester.init(.{ .invoker = invoker });
    defer tester.deinit();

    const TestScript = ServiceScriptGen.Task("Test Script", struct {
        fn f(_: *const Delegate, bld: *ContainerBuild) anyerror!void {
            try bld.constant("foo").assign(bld.x.raw("undefined"));
        }
    }.f, .{});

    try expectServiceScript(
        \\// header
        \\const foo = undefined;
    , TestScript, tester.pipeline, .{});
}
