const std = @import("std");
const fs = std.fs;
const jobz = @import("jobz");
const DirOptions = @import("razdaz/jobs").files.DirOptions;
const prelude = @import("prelude.zig");
const rls = @import("systems/rules.zig");
const trt = @import("systems/traits.zig");
const isu = @import("systems/issues.zig");
const SymbolsProvider = @import("systems/symbols.zig").SymbolsProvider;
const RawModel = @import("parse/RawModel.zig");
const ParseModel = @import("parse/parse.zig").ParseModel;
const ParseBehavior = @import("parse/issues.zig").ParseBehavior;
const CodegenService = @import("gen/service.zig").CodegenService;
const CodegnBehavior = @import("gen/issues.zig").CodegenBehavior;
const JsonReader = @import("utils/JsonReader.zig");

pub const ScopeTag = enum {
    slug,
    parse_behavior,
    codegen_behavior,
};

pub const PipelineBehavior = struct {
    process: isu.IssueBehavior = .abort,
    parse: isu.IssueBehavior = .abort,
    codegen: isu.IssueBehavior = .abort,
};

pub const PipelineOptions = struct {
    traits: ?trt.TraitsRegistry = null,
    rules_builtins: rls.BuiltInsRegistry = &.{},
    rules_funcs: rls.FunctionsRegistry = &.{},
    behavior_service: PipelineBehavior = .{},
    behavior_parse: ParseBehavior = .{},
    behavior_codegen: CodegnBehavior = .{},
};

pub const PipelineServiceFilterHook = jobz.Task.Hook("Smithy Service Filter", bool, &.{[]const u8});

pub const Pipeline = jobz.Task.Define("Smithy Service Pipeline", smithyTask, .{});
fn smithyTask(self: *const jobz.Delegate, src_dir: fs.Dir, options: PipelineOptions) anyerror!void {
    const behavior = options.behavior_service;
    try self.defineValue(ParseBehavior, ScopeTag.parse_behavior, options.behavior_parse);
    try self.defineValue(CodegnBehavior, ScopeTag.codegen_behavior, options.behavior_codegen);

    const traits_manager: *trt.TraitsManager = try self.provide(trt.TraitsManager{}, null);
    try prelude.registerTraits(self.alloc(), traits_manager);
    if (options.traits) |registry| {
        try traits_manager.registerAll(self.alloc(), registry);
    }

    _ = try self.provide(try rls.RulesEngine.init(self.alloc(), options.rules_builtins, options.rules_funcs), null);

    var it = src_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        processService(self, src_dir, entry.name, behavior) catch |err| switch (behavior.process) {
            .abort => {
                std.log.err("Processing model '{s}' failed: {s}", .{ entry.name, @errorName(err) });
                if (@errorReturnTrace()) |t| std.debug.dumpStackTrace(t.*);
                return isu.AbortError;
            },
            .skip => {
                std.log.err("Skipped model '{s}': {s}", .{ entry.name, @errorName(err) });
                return;
            },
        };
    }
}

fn processService(self: *const jobz.Delegate, src_dir: fs.Dir, filename: []const u8, behavior: PipelineBehavior) !void {
    if (self.hasOverride(PipelineServiceFilterHook)) {
        const allowed = try self.evaluate(PipelineServiceFilterHook, .{filename});
        if (!allowed) return;
    }

    try self.evaluate(SmithyService, .{ src_dir, filename, behavior });
}

const SmithyService = jobz.Task.Define("Smithy Service", smithyServiceTask, .{});
fn smithyServiceTask(self: *const jobz.Delegate, src_dir: fs.Dir, json_name: []const u8, behavior: PipelineBehavior) anyerror!void {
    std.debug.assert(std.mem.endsWith(u8, json_name, ".json"));
    const slug = json_name[0 .. json_name.len - ".json".len];
    try self.defineValue([]const u8, ScopeTag.slug, slug);

    const issues: *isu.IssuesBag = try self.provide(isu.IssuesBag.init(self.alloc()), null);

    var symbols = serviceReadAndParse(self, src_dir, json_name) catch |err| {
        return handleIssue(issues, behavior.parse, err, .parse_error, "Parsing failed", @errorReturnTrace());
    };
    _ = try self.provide(&symbols, null);

    self.evaluate(CodegenService, .{ slug, DirOptions{
        .create_on_not_found = true,
        .delete_on_error = true,
    } }) catch |err| {
        return handleIssue(issues, behavior.codegen, err, .codegen_error, "Codegen failed", @errorReturnTrace());
    };
}

fn serviceReadAndParse(self: *const jobz.Delegate, src_dir: fs.Dir, json_name: []const u8) !SymbolsProvider {
    const json_file: fs.File = try src_dir.openFile(json_name, .{});
    defer json_file.close();

    var reader = try JsonReader.initPersist(self.alloc(), json_file);
    defer reader.deinit();

    var model: RawModel = try self.evaluate(ParseModel, .{&reader});
    return model.consume(self.alloc());
}

fn handleIssue(
    issues: *isu.IssuesBag,
    behavior: isu.IssueBehavior,
    err: anyerror,
    comptime tag: anytype,
    message: []const u8,
    stack_trace: ?*std.builtin.StackTrace,
) !void {
    switch (err) {
        isu.AbortError => return err,
        else => switch (behavior) {
            .abort => {
                std.log.err("{s}: {s}", .{ message, @errorName(err) });
                if (stack_trace) |trace| std.debug.dumpStackTrace(trace.*);
                return isu.AbortError;
            },
            .skip => {
                issues.add(@unionInit(isu.Issue, @tagName(tag), err)) catch {};
                return;
            },
        },
    }
}
