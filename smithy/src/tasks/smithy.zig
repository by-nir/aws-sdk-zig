const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const pipez = @import("../pipeline/root.zig");
const Task = pipez.Task;
const Delegate = pipez.Delegate;
const AbstractTask = pipez.AbstractTask;
const AbstractEval = pipez.AbstractEval;
const md = @import("../codegen/md.zig");
const zig = @import("../codegen/zig.zig");
const ContainerBuild = zig.ContainerBuild;
const Writer = @import("../codegen/CodegenWriter.zig");
const rls = @import("../systems/rules.zig");
const trt = @import("../systems/traits.zig");
const SymbolsProvider = @import("../systems/symbols.zig").SymbolsProvider;
const name_util = @import("../utils/names.zig");
const IssuesBag = @import("../utils/IssuesBag.zig");
const JsonReader = @import("../utils/JsonReader.zig");
const prelude = @import("../prelude.zig");
const trt_docs = @import("../traits/docs.zig");
const files_tasks = @import("files.zig");
const codegen_tasks = @import("codegen.zig");
const smithy_parse = @import("smithy_parse.zig");
const smithy_codegen = @import("smithy_codegen.zig");

pub const ServiceFilterHook = Task.Hook("Smithy Service Filter", bool, &.{[]const u8});
pub const ScriptCodegenHeadHook = Task.Hook("Smithy Script Head", anyerror!void, &.{*ContainerBuild});
pub const ServiceCodegenReadmeHook = codegen_tasks.MarkdownDoc.Hook("Smithy Service Readme Codegen", &.{ReadmeMetadata});

pub const ReadmeMetadata = struct {
    /// `{[slug]s}` service SDK ID
    slug: []const u8,
    /// `{[title]s}` service title
    title: []const u8,
    /// `{[intro]s}` introduction description
    intro: ?[]const u8,
};

pub const ScopeTag = enum {
    slug,
    parse_policy,
    codegen_policy,
};

pub const ServicePolicy = struct {
    process: IssuesBag.PolicyResolution = .abort,
    parse: IssuesBag.PolicyResolution = .abort,
    codegen: IssuesBag.PolicyResolution = .abort,
};

pub const SmithyOptions = struct {
    traits: ?trt.TraitsRegistry = null,
    rules_builtins: rls.BuiltInsRegistry = &.{},
    rules_funcs: rls.FunctionsRegistry = &.{},
    policy_service: ServicePolicy = .{},
    policy_parse: smithy_parse.ParsePolicy = .{},
    policy_codegen: smithy_codegen.CodegenPolicy = .{},
};

pub const Smithy = Task.Define("Smithy", smithyTask, .{});
fn smithyTask(self: *const Delegate, src_dir: fs.Dir, options: SmithyOptions) anyerror!void {
    const policy = options.policy_service;
    try self.defineValue(smithy_parse.ParsePolicy, ScopeTag.parse_policy, options.policy_parse);
    try self.defineValue(smithy_codegen.CodegenPolicy, ScopeTag.codegen_policy, options.policy_codegen);

    const traits_manager: *trt.TraitsManager = try self.provide(trt.TraitsManager{}, struct {
        fn clean(service: *trt.TraitsManager, allocator: Allocator) void {
            service.deinit(allocator);
        }
    }.clean);
    try prelude.registerTraits(self.alloc(), traits_manager);
    if (options.traits) |registry| {
        try traits_manager.registerAll(self.alloc(), registry);
    }

    _ = try self.provide(try rls.RulesEngine.init(self.alloc(), options.rules_builtins, options.rules_funcs), struct {
        fn clean(service: *rls.RulesEngine, allocator: Allocator) void {
            service.deinit(allocator);
        }
    }.clean);

    var it = src_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        processService(self, src_dir, entry.name, policy) catch |err| switch (policy.process) {
            .abort => {
                std.log.err("Processing model '{s}' failed: {s}", .{ entry.name, @errorName(err) });
                if (@errorReturnTrace()) |t| std.debug.dumpStackTrace(t.*);
                return IssuesBag.PolicyAbortError;
            },
            .skip => {
                std.log.err("Skipped model '{s}': {s}", .{ entry.name, @errorName(err) });
                return;
            },
        };
    }
}

fn processService(self: *const Delegate, src_dir: fs.Dir, filename: []const u8, policy: ServicePolicy) !void {
    if (self.hasOverride(ServiceFilterHook)) {
        const allowed = try self.evaluate(ServiceFilterHook, .{filename});
        if (!allowed) return;
    }

    try self.evaluate(SmithyService, .{ src_dir, filename, policy });
}

const SmithyService = Task.Define("Smithy Service", smithyServiceTask, .{});
fn smithyServiceTask(
    self: *const Delegate,
    src_dir: fs.Dir,
    json_name: []const u8,
    policy: ServicePolicy,
) anyerror!void {
    std.debug.assert(std.mem.endsWith(u8, json_name, ".json"));
    const slug = json_name[0 .. json_name.len - ".json".len];
    try self.defineValue([]const u8, ScopeTag.slug, slug);

    const issues: *IssuesBag = try self.provide(IssuesBag.init(self.alloc()), null);

    var symbols = serviceReadAndParse(self, src_dir, json_name) catch |err| {
        return handlePolicy(issues, policy.parse, err, .parse_error, "Parsing failed", @errorReturnTrace());
    };
    _ = try self.provide(&symbols, null);

    try symbols.enqueue(symbols.service_id);
    self.evaluate(ServiceCodegen, .{ slug, files_tasks.DirOptions{
        .create_on_not_found = true,
        .delete_on_error = true,
    } }) catch |err| {
        return handlePolicy(issues, policy.codegen, err, .codegen_error, "Codegen failed", @errorReturnTrace());
    };
}

fn serviceReadAndParse(self: *const Delegate, src_dir: fs.Dir, json_name: []const u8) !SymbolsProvider {
    const json_file: fs.File = try src_dir.openFile(json_name, .{});
    defer json_file.close();

    var reader = try JsonReader.initPersist(self.alloc(), json_file);
    defer reader.deinit();

    var model: smithy_parse.Model = try self.evaluate(smithy_parse.ServiceParse, .{&reader});
    return model.consume(self.alloc());
}

fn handlePolicy(
    issues: *IssuesBag,
    policy: IssuesBag.PolicyResolution,
    err: anyerror,
    comptime tag: anytype,
    message: []const u8,
    stack_trace: ?*std.builtin.StackTrace,
) !void {
    switch (err) {
        IssuesBag.PolicyAbortError => return err,
        else => switch (policy) {
            .abort => {
                std.log.err("{s}: {s}", .{ message, @errorName(err) });
                if (stack_trace) |trace| std.debug.dumpStackTrace(trace.*);
                return IssuesBag.PolicyAbortError;
            },
            .skip => {
                issues.add(@unionInit(IssuesBag.Issue, @tagName(tag), err)) catch {};
                return;
            },
        },
    }
}

const ServiceCodegen = files_tasks.OpenDir.Task("Service Codegen", serviceCodegenTask, .{});
fn serviceCodegenTask(self: *const Delegate) anyerror!void {
    try self.evaluate(
        files_tasks.WriteFile.Chain(smithy_codegen.ServiceCodegenClient, .sync),
        .{ "client.zig", files_tasks.FileOptions{ .delete_on_error = true } },
    );

    if (self.hasOverride(ServiceCodegenReadmeHook)) {
        try self.evaluate(ServiceGenReadme, .{ "README.md", .{} });
    } else {
        std.log.warn("Skipped readme generation – missing `CodegenScriptHeadHook` overide.", .{});
    }
}

const ServiceGenReadme = files_tasks.WriteFile.Task("Service Readme Codegen", serviceGenReadmeTask, .{
    .injects = &.{SymbolsProvider},
});
fn serviceGenReadmeTask(
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

    try self.evaluate(ServiceCodegenReadmeHook, .{ writer, ReadmeMetadata{
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

test "ServiceGenReadme" {
    const invoker = comptime blk: {
        var builder = pipez.InvokerBuilder{};

        _ = builder.Override(ServiceCodegenReadmeHook, "Test Readme", struct {
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

    const output = try files_tasks.evaluateWriteFile(test_alloc, tester.pipeline, ServiceGenReadme, .{});
    defer test_alloc.free(output);
    try codegen_tasks.expectEqualMarkdownDoc("## Foo Service", output);
}

pub const ServiceScriptGen = codegen_tasks.ZigScript.Abstract(
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

    if (self.hasOverride(ScriptCodegenHeadHook)) {
        try self.evaluate(ScriptCodegenHeadHook, .{bld});
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

        _ = builder.Override(ScriptCodegenHeadHook, "Test Script Head", struct {
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
