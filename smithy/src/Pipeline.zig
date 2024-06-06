//! Process and generate Smithy services.
//! - `<service_name>/`
//!   - `README.md`
//!   - `client.zig`
const std = @import("std");
const fs = std.fs;
const log = std.log;
const Timer = std.time.Timer;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const parse = @import("parse.zig");
const prelude = @import("prelude.zig");
const codegen = @import("codegen.zig");
const md = @import("codegen/md.zig");
const Writer = @import("codegen/CodegenWriter.zig");
const syb_traits = @import("symbols/traits.zig");
const SmithyModel = @import("symbols/shapes.zig").SmithyModel;
const IssuesBag = @import("utils/IssuesBag.zig");
const JsonReader = @import("utils/JsonReader.zig");
const titleCase = @import("utils/names.zig").titleCase;
const trt_docs = @import("traits/docs.zig");

const Self = @This();

const Options = struct {
    /// Absolute path.
    src_dir_absolute: []const u8,
    /// Relative to the working directory.
    out_dir_relative: []const u8,
    parse_policy: parse.Policy,
    codegen_policy: codegen.Policy,
    process_policy: Policy,
};

pub const Policy = struct {
    model: IssuesBag.PolicyResolution,
    readme: IssuesBag.PolicyResolution,
};

pub const Hooks = struct {
    writeReadme: ?*const fn (Allocator, std.io.AnyWriter, *const SmithyModel, ReadmeMeta) anyerror!void = null,

    pub const ReadmeMeta = struct {
        /// `{[title]s}` service title
        title: []const u8,
        /// `{[slug]s}` service SDK ID
        slug: []const u8,
        /// `{[intro]s}` introduction description
        intro: ?[]const u8,
    };
};

gpa_alloc: Allocator,
page_alloc: Allocator,
issues: IssuesBag,
traits: syb_traits.TraitsManager,
process_hooks: Hooks,
codegen_hooks: codegen.Hooks,
src_dir: fs.Dir,
out_dir: fs.Dir,
parse_policy: parse.Policy,
codegen_policy: codegen.Policy,
process_policy: Policy,

pub fn init(
    gpa_alloc: Allocator,
    page_alloc: Allocator,
    options: Options,
    process_hooks: Hooks,
    codegen_hooks: codegen.Hooks,
) !*Self {
    const self = try gpa_alloc.create(Self);
    self.gpa_alloc = gpa_alloc;
    self.page_alloc = page_alloc;
    self.process_hooks = process_hooks;
    self.codegen_hooks = codegen_hooks;
    self.parse_policy = options.parse_policy;
    self.codegen_policy = options.codegen_policy;
    self.process_policy = options.process_policy;
    errdefer gpa_alloc.destroy(self);

    self.traits = syb_traits.TraitsManager{};
    errdefer self.traits.deinit(gpa_alloc);
    try prelude.registerTraits(gpa_alloc, &self.traits);

    self.issues = IssuesBag.init(gpa_alloc);
    errdefer self.issues.deinit();

    self.src_dir = try fs.openDirAbsolute(options.src_dir_absolute, .{
        .iterate = true,
    });
    errdefer self.src_dir.close();
    self.out_dir = try fs.cwd().makeOpenPath(options.out_dir_relative, .{});

    return self;
}

pub fn deinit(self: *Self) void {
    self.traits.deinit(self.gpa_alloc);
    self.issues.deinit();
    self.src_dir.close();
    self.out_dir.close();
    self.gpa_alloc.destroy(self);
}

pub fn registerTraits(self: *Self, traits: syb_traits.TraitsRegistry) !void {
    try self.traits.registerAll(self.gpa_alloc, traits);
}

/// A `filename` is the model’s file name ending with `.json` extension.
pub fn processFiles(self: *Self, filenames: []const []const u8) !Report {
    var arena = std.heap.ArenaAllocator.init(self.page_alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    var report = Report{};

    for (filenames) |filename| {
        if (!isValidModelFilename(filename)) continue;
        defer _ = arena.reset(.retain_capacity);
        processModel(self, arena_alloc, &report, filename) catch |err| {
            log.err("Process error: {s}", .{@errorName(err)});
            return err;
        };
    }

    return report;
}

/// `filter` is an optional whitelist of models to process; an empty list will
/// process **all** models.
pub fn processAll(self: *Self, filter: ?*const fn (filename: []const u8) bool) !Report {
    var arena = std.heap.ArenaAllocator.init(self.page_alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    var report = Report{};

    var it = self.src_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file or !isValidModelFilename(entry.name)) continue;
        if (filter) |f| if (!f(entry.name)) {
            log.debug("[Filter] Skipping model `{s}`", .{entry.name});
            continue;
        };
        defer _ = arena.reset(.retain_capacity);

        processModel(self, arena_alloc, &report, entry.name) catch |err| {
            log.err("Process failed: {s}", .{@errorName(err)});
            return err;
        };
    }

    return report;
}

fn isValidModelFilename(name: []const u8) bool {
    return name.len > 5 and std.mem.endsWith(u8, name, ".json");
}

fn processModel(self: *Self, arena: Allocator, report: *Report, json_name: []const u8) !void {
    var timer = try Timer.start();
    var issues = IssuesBag.init(arena);
    defer issues.deinit();

    log.info("Processing model `{s}`", .{json_name});
    _ = &timer; // autofix
    _ = report; // autofix

    const model = self.parseModel(arena, json_name, &issues) catch |err| {
        switch (err) {
            IssuesBag.PolicyAbortError => return err,
            else => switch (self.process_policy.model) {
                .abort => {
                    log.err("Parse failed: {s}", .{@errorName(err)});
                    return err;
                },
                .skip => {
                    try issues.add(.{ .process_error = err });
                    return;
                },
            },
        }
    };

    const slug = json_name[0 .. json_name.len - ".json".len];
    var out_dir = try self.out_dir.makeOpenPath(slug, .{});
    defer out_dir.close();
    errdefer out_dir.deleteTree(slug) catch |err| {
        log.err("Deleting model’s output dir failed: {s}", .{@errorName(err)});
    };

    self.generateScript(arena, &model, out_dir, &issues) catch |err| {
        switch (err) {
            IssuesBag.PolicyAbortError => return err,
            else => switch (self.process_policy.model) {
                .abort => {
                    log.err("Codegen failed: {s}", .{@errorName(err)});
                    return err;
                },
                .skip => {
                    try issues.add(.{ .codegen_error = err });
                    return;
                },
            },
        }
    };

    self.generateReadme(arena, &model, out_dir, slug) catch |err| {
        switch (self.process_policy.readme) {
            .abort => {
                log.err("Readme failed: {s}", .{@errorName(err)});
                return err;
            },
            .skip => {
                try issues.add(.{ .readme_error = err });
                return;
            },
        }
    };
}

fn parseModel(self: *Self, arena: Allocator, json_name: []const u8, issues: *IssuesBag) !SmithyModel {
    var json_file = try self.src_dir.openFile(json_name, .{});
    defer json_file.close();

    var reader = try JsonReader.initFile(arena, json_file);
    defer reader.deinit();

    return parse.parseJson(arena, self.traits, self.parse_policy, issues, &reader);
}

fn generateScript(self: *Self, arena: Allocator, model: *const SmithyModel, dir: fs.Dir, issues: *IssuesBag) !void {
    var file = try dir.createFile("client.zig", .{});
    defer file.close();

    const zig_head = @embedFile("codegen/template/head.zig.template") ++ "\n\n";
    try file.writer().writeAll(zig_head);
    try codegen.writeScript(
        arena,
        file.writer().any(),
        self.codegen_hooks,
        self.codegen_policy,
        issues,
        model,
        model.service,
    );
}

fn generateReadme(self: *Self, arena: Allocator, model: *const SmithyModel, dir: fs.Dir, slug: []const u8) !void {
    const hook = self.process_hooks.writeReadme orelse return;
    const title =
        trt_docs.Title.get(model, model.service) orelse
        try titleCase(arena, slug);
    const intro: ?[]const u8 = if (trt_docs.Documentation.get(model, model.service)) |docs| blk: {
        var build = md.Document.Build{ .allocator = arena };
        try md.convertHtml(arena, &build, docs);
        const markdown = try build.consume();
        defer markdown.deinit(arena);

        var output = std.ArrayList(u8).init(arena);
        errdefer output.deinit();

        var writer = Writer.init(arena, output.writer().any());
        defer writer.deinit();

        try markdown.write(&writer);
        break :blk try output.toOwnedSlice();
    } else null;

    var file = try dir.createFile("README.md", .{});
    defer file.close();

    const md_head = @embedFile("codegen/template/head.md.template") ++ "\n\n";
    try file.writer().writeAll(md_head);
    try hook(arena, file.writer().any(), model, Hooks.ReadmeMeta{
        .slug = slug,
        .title = title,
        .intro = intro,
    });
}

pub const Report = struct {
};
