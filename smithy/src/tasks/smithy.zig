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
const rls = @import("../systems/rules.zig");
const trt = @import("../systems/traits.zig");
const SymbolsProvider = @import("../systems/symbols.zig").SymbolsProvider;
const name_util = @import("../utils/names.zig");
const IssuesBag = @import("../utils/IssuesBag.zig");
const JsonReader = @import("../utils/JsonReader.zig");
const prelude = @import("../prelude.zig");
const trt_docs = @import("../traits/docs.zig");
const files_tasks = @import("files.zig");
const smithy_parse = @import("smithy_parse.zig");
const smithy_codegen = @import("smithy_codegen.zig");

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

pub const ServiceFilterHook = Task.Hook("Smithy Service Filter", bool, &.{[]const u8});

pub const Smithy = Task.Define("Smithy", smithyTask, .{});
fn smithyTask(self: *const Delegate, src_dir: fs.Dir, options: SmithyOptions) anyerror!void {
    const policy = options.policy_service;
    try self.defineValue(smithy_parse.ParsePolicy, ScopeTag.parse_policy, options.policy_parse);
    try self.defineValue(smithy_codegen.CodegenPolicy, ScopeTag.codegen_policy, options.policy_codegen);

    const traits_manager: *trt.TraitsManager = try self.provide(trt.TraitsManager{}, null);
    try prelude.registerTraits(self.alloc(), traits_manager);
    if (options.traits) |registry| {
        try traits_manager.registerAll(self.alloc(), registry);
    }

    _ = try self.provide(try rls.RulesEngine.init(self.alloc(), options.rules_builtins, options.rules_funcs), null);

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

    self.evaluate(smithy_codegen.ServiceCodegen, .{ slug, files_tasks.DirOptions{
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
