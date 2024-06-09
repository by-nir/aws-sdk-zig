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
const prelude = @import("prelude.zig");
const Parser = @import("parse/Parser.zig");
const Generator = @import("codegen/Generator.zig");
const Writer = @import("codegen/CodegenWriter.zig");
const SymbolsProvider = @import("systems/symbols.zig").SymbolsProvider;
const trt = @import("systems/traits.zig");
const IssuesBag = @import("utils/IssuesBag.zig");
const JsonReader = @import("utils/JsonReader.zig");

const Self = @This();

const Options = struct {
    /// Absolute path.
    src_dir_absolute: []const u8,
    /// Relative to the working directory.
    out_dir_relative: []const u8,
    parse_policy: Parser.Policy,
    codegen_policy: Generator.Policy,
    process_policy: Policy,
};

pub const Policy = struct {
    model: IssuesBag.PolicyResolution,
    readme: IssuesBag.PolicyResolution,
};

gpa_alloc: Allocator,
page_alloc: Allocator,
traits_manager: trt.TraitsManager,
parser: Parser,
generator: Generator,
process_policy: Policy,
src_dir: fs.Dir,
out_dir: fs.Dir,

pub fn init(gpa_alloc: Allocator, page_alloc: Allocator, options: Options, hooks: Generator.Hooks) !*Self {
    const self = try gpa_alloc.create(Self);
    self.gpa_alloc = gpa_alloc;
    self.page_alloc = page_alloc;
    self.process_policy = options.process_policy;
    errdefer gpa_alloc.destroy(self);

    self.traits_manager = .{};
    errdefer self.traits_manager.deinit(gpa_alloc);
    try prelude.registerTraits(gpa_alloc, &self.traits_manager);

    self.parser = .{
        .policy = options.parse_policy,
        .traits_manager = &self.traits_manager,
    };

    self.generator = .{
        .policy = options.codegen_policy,
        .hooks = hooks,
    };

    self.src_dir = try fs.openDirAbsolute(options.src_dir_absolute, .{
        .iterate = true,
    });
    errdefer self.src_dir.close();
    self.out_dir = try fs.cwd().makeOpenPath(options.out_dir_relative, .{});

    return self;
}

pub fn deinit(self: *Self) void {
    self.traits_manager.deinit(self.gpa_alloc);
    self.src_dir.close();
    self.out_dir.close();
    self.gpa_alloc.destroy(self);
}

pub fn registerTraits(self: *Self, traits: trt.TraitsRegistry) !void {
    try self.traits_manager.registerAll(self.gpa_alloc, traits);
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
        self.processModel(arena_alloc, &report, filename) catch |err| {
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

        self.processModel(arena_alloc, &report, entry.name) catch |err| {
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

    var symbols = self.parseModel(arena, json_name, &issues) catch |err| {
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
    defer symbols.deinit();

    const slug = json_name[0 .. json_name.len - ".json".len];
    var out_dir = try self.out_dir.makeOpenPath(slug, .{});
    defer out_dir.close();
    errdefer out_dir.deleteTree(slug) catch |err| {
        log.err("Deleting model’s output dir failed: {s}", .{@errorName(err)});
    };

    try symbols.enqueue(symbols.service_id);
    self.generateScript(arena, &symbols, out_dir, &issues) catch |err| {
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

    if (self.generator.hooks.writeReadme != null) {
        self.generateReadme(arena, &symbols, out_dir, slug) catch |err| {
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

}

fn parseModel(self: *Self, arena: Allocator, json_name: []const u8, issues: *IssuesBag) !SymbolsProvider {
    var json_file = try self.src_dir.openFile(json_name, .{});
    defer json_file.close();

    var reader = try JsonReader.initFile(arena, json_file);
    defer reader.deinit();

    var model = try self.parser.parseJson(arena, issues, &reader);
    errdefer model.deinit();

    return model.consume(arena);
}

fn generateScript(
    self: *Self,
    arena: Allocator,
    symbols: *SymbolsProvider,
    dir: fs.Dir,
    issues: *IssuesBag,
) !void {
    var file = try dir.createFile("client.zig", .{});
    var file_buffer = std.io.bufferedWriter(file.writer());
    defer file.close();

    const zig_head = @embedFile("codegen/template/head.zig.template") ++ "\n\n";
    try file_buffer.writer().writeAll(zig_head);
    try self.generator.writeScript(arena, symbols, issues, file_buffer.writer().any());
    try file_buffer.flush();
}

fn generateReadme(self: *Self, arena: Allocator, symbols: *SymbolsProvider, dir: fs.Dir, slug: []const u8) !void {
    var file = try dir.createFile("README.md", .{});
    var file_buffer = std.io.bufferedWriter(file.writer());
    defer file.close();

    const md_head = @embedFile("codegen/template/head.md.template") ++ "\n\n";
    try file_buffer.writer().writeAll(md_head);
    try self.generator.writeReadme(arena, symbols, slug, file_buffer.writer().any());
    try file_buffer.flush();
}

pub const Report = struct {
};
