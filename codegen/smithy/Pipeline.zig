//! Process and generate Smithy services.
//! - `<service_name>/`
//!   - `README.md`
//!   - `client.zig`
const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const parse = @import("parse.zig");
const prelude = @import("prelude.zig");
const generate = @import("generate.zig");
const Markdown = @import("generate/Markdown.zig");
const syb_traits = @import("symbols/traits.zig");
const SmithyModel = @import("symbols/shapes.zig").SmithyModel;
const IssuesBag = @import("utils/IssuesBag.zig");
const JsonReader = @import("utils/JsonReader.zig");
const StackWriter = @import("utils/StackWriter.zig");
const titleCase = @import("utils/names.zig").titleCase;
const trt_docs = @import("prelude/docs.zig");

const Self = @This();

const Options = struct {
    /// Absolute path.
    src_dir_absolute: []const u8,
    /// Relative to the working directory.
    out_dir_relative: []const u8,
    parse_policy: parse.Policy,
    codegen_policy: generate.Policy,
};

pub const Hooks = struct {
    writeReadme: ?*const fn (std.io.AnyWriter, *const SmithyModel, ReadmeMeta) anyerror!void = null,

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
codegen_hooks: generate.Hooks,
src_dir: fs.Dir,
out_dir: fs.Dir,
parse_policy: parse.Policy,
codegen_policy: generate.Policy,

pub fn init(
    gpa_alloc: Allocator,
    page_alloc: Allocator,
    options: Options,
    process_hooks: Hooks,
    codegen_hooks: generate.Hooks,
) !*Self {
    const self = try gpa_alloc.create(Self);
    self.gpa_alloc = gpa_alloc;
    self.page_alloc = page_alloc;
    self.process_hooks = process_hooks;
    self.codegen_hooks = codegen_hooks;
    self.parse_policy = options.parse_policy;
    self.codegen_policy = options.codegen_policy;
    errdefer gpa_alloc.destroy(self);

    self.traits = syb_traits.TraitsManager{};
    try prelude.registerTraits(gpa_alloc, &self.traits);
    errdefer self.traits.deinit(gpa_alloc);

    self.issues = IssuesBag.init(gpa_alloc);
    errdefer self.issues.deinit();

    self.src_dir = try fs.openDirAbsolute(options.src_dir_absolute, .{
        .iterate = true,
    });
    errdefer self.src_dir.close();
    self.out_dir = try fs.cwd().openDir(options.out_dir_relative, .{});

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
    defer arena.deinit();

    const report = Report{};
    var timer = std.time.Timer.start() catch unreachable;

    for (filenames) |filename| {
        if (!isValidModelFilename(filename)) continue;
        defer _ = arena.reset(.retain_capacity);

        if (self.processModel(arena.allocator(), filename)) |issues| {
            _ = timer.lap();
            issues.deinit();
        } else |e| {
            _ = timer.lap();
            return e;
        }
    }

    return report;
}

/// `filter` is an optional whitelist of models to process; an empty list will
/// process **all** models.
pub fn processAll(self: *Self, filter: ?*const fn (filename: []const u8) bool) !Report {
    var arena = std.heap.ArenaAllocator.init(self.page_alloc);
    defer arena.deinit();

    const report = Report{};
    var timer = std.time.Timer.start() catch unreachable;

    var it = self.src_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file or !isValidModelFilename(entry.name)) continue;
        if (filter) |f| if (!f(entry.name)) {
            std.log.debug("[Filter] Skipping model `{s}`", .{entry.name});
            continue;
        };
        defer _ = arena.reset(.retain_capacity);

        if (self.processModel(arena.allocator(), entry.name)) |issues| {
            _ = timer.lap();
            issues.deinit();
        } else |e| {
            _ = timer.lap();
            return e;
        }
    }

    return report;
}

fn isValidModelFilename(name: []const u8) bool {
    return name.len > 5 and std.mem.endsWith(u8, name, ".json");
}

fn processModel(self: *Self, arena: Allocator, json_name: []const u8) !IssuesBag {
    std.log.info("Processing model `{s}`", .{json_name});

    var issues = IssuesBag.init(arena);
    errdefer issues.deinit();

    const model = self.parseModel(arena, json_name, &issues) catch |e| {
        switch (e) {
            IssuesBag.PolicyAbortError => {},
            else => issues.add(.{ .parse_error = e }) catch unreachable,
        }
        return e;
    };
    try self.generateModel(arena, json_name, &model, &issues) catch |e| {
        switch (e) {
            IssuesBag.PolicyAbortError => {},
            else => issues.add(.{ .codegen_error = e }) catch unreachable,
        }
        return e;
    };

    return issues;
}

fn parseModel(self: *Self, arena: Allocator, json_name: []const u8, issues: *IssuesBag) !SmithyModel {
    var json_file = self.src_dir.openFile(json_name, .{}) catch |e| {
        return e;
    };
    defer json_file.close();

    var json = JsonReader.initFile(arena, json_file) catch |e| {
        return e;
    };
    defer json.deinit();

    return parse.parseJson(arena, self.traits, self.parse_policy, issues, &json);
}

fn generateModel(
    self: *Self,
    arena: Allocator,
    json_name: []const u8,
    model: *const SmithyModel,
    issues: *IssuesBag,
) !void {
    const slug = json_name[0 .. json_name.len - ".json".len];
    var out_dir = self.out_dir.makeOpenPath(slug, .{}) catch |e| {
        return e;
    };
    errdefer out_dir.deleteTree(slug) catch unreachable;

    var file = out_dir.createFile("client.zig", .{}) catch |e| {
        return e;
    };
    errdefer file.close();

    const zig_head = @embedFile("template/head.zig.template") ++ "\n\n";
    file.writer().writeAll(zig_head) catch |e| {
        return e;
    };
    if (generate.writeScript(
        arena,
        file.writer().any(),
        self.codegen_hooks,
        self.codegen_policy,
        issues,
        model,
        model.service,
    )) {
        file.close();
    } else |e| {
        return e;
    }

    if (self.process_hooks.writeReadme) |readmeHook| {
        const title = trt_docs.Title.get(model, model.service) orelse titleCase(arena, slug) catch |e| {
            return e;
        };
        var intro: ?[]const u8 = null;
        if (trt_docs.Documentation.get(model, model.service)) |docs| {
            var intro_buffer = std.ArrayList(u8).init(arena);
            errdefer intro_buffer.deinit();
            var intro_writer = StackWriter.init(arena, intro_buffer.writer().any(), .{});
            var md = Markdown.init(&intro_writer);
            try md.writeSource(docs);
            try md.end();
            intro = try intro_buffer.toOwnedSlice();
        }

        file = out_dir.createFile("README.md", .{}) catch |e| {
            return e;
        };
        const md_head = @embedFile("template/head.md.template") ++ "\n\n";
        file.writer().writeAll(md_head) catch |e| {
            return e;
        };
        if (readmeHook(file.writer().any(), model, Hooks.ReadmeMeta{
            .slug = slug,
            .title = title,
            .intro = intro,
        })) {
            file.close();
        } else |e| {
            return e;
        }
    }

    out_dir.close();
}

pub const Report = struct {
};
