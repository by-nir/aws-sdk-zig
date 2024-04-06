const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const options = @import("codegen-options");
const filter: []const []const u8 = options.filter;
const models_path: []const u8 = options.models_path;
const install_path: []const u8 = options.install_path;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    var models_dir = try fs.openDirAbsolute(models_path, .{
        .iterate = true,
        .access_sub_paths = true,
    });
    defer models_dir.close();

    var count_models: usize = 0;
    var count_shapes: usize = 0;
    var duration: u64 = 0;

    if (filter.len > 0) {
        // Process filtered models
        for (filter) |model_path| {
            defer _ = arena.reset(.retain_capacity);
            const filename = try std.fmt.allocPrint(arena.allocator(), "{s}.json", .{model_path});
            if (processModelFile(arena.allocator(), models_dir, filename)) |stats| {
                count_models += 1;
                count_shapes += stats.shapes;
                duration += stats.duration_ns;
            }
        }
    } else {
        // Process all models
        var it = models_dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
            if (std.mem.startsWith(u8, entry.name, "sdk-")) continue;
            defer _ = arena.reset(.retain_capacity);
            if (processModelFile(arena.allocator(), models_dir, entry.name)) |stats| {
                count_models += 1;
                count_shapes += stats.shapes;
                duration += stats.duration_ns;
            }
        }
    }

    std.log.info(
        "Processed {d} {s} containing {d} Smithy shapes within {d:.2} seconds\n",
        .{ count_models, if (count_models == 1) "model" else "models", count_shapes, @as(f64, @floatFromInt(duration)) / std.time.ns_per_s },
    );
}

const ParseStats = struct { shapes: usize, duration_ns: u64 };

fn processModelFile(arena: Allocator, models_dir: fs.Dir, filename: []const u8) ?ParseStats {
    const file = models_dir.openFile(filename, .{}) catch |e| {
        std.debug.print("Failed opening model `{s}`: {s}.\n", .{ filename, @errorName(e) });
        return null;
    };
    defer file.close();

    std.log.info("Start processing model {s}\n", .{filename});
    const start = std.time.Instant.now() catch unreachable;
    const shape_count = processModel(arena, file.reader().any()) catch |e| {
        std.debug.print(
            "Failed processing model `{s}`: {s}.{any}\n",
            .{ filename, @errorName(e), @errorReturnTrace() },
        );
        return null;
    };
    const end = std.time.Instant.now() catch unreachable;
    return .{ .shapes = shape_count, .duration_ns = end.since(start) };
}

fn processModel(arena: Allocator, file_reader: std.io.AnyReader) !usize { // raw_model: []const u8
    var reader = std.json.reader(arena, file_reader);

    var parser = Parser{
        .arena = arena,
        .reader = &reader,
        // .model = &model,
    };

    try parser.expectObjectBegin();
    try parser.expectString("smithy");
    try parser.expectString("2.0");
    while (true) {
        // For now we skip non-shapes sections (like metadata)
        const token = try parser.nextString();
        if (std.mem.eql(u8, "shapes", token)) break;
        try parser.expectObjectBegin();
        try parser.skipObject();
    }

    try parser.expectObjectBegin();
    var shape_count: usize = 0;
    while (true) {
        switch (try parser.nextToken()) {
            .object_end => break,
            .string, .allocated_string => |name| {
                try parser.expectObjectBegin();
                try parser.nextShape(name);
                // try parser.skipObject();
            },
            else => unreachable,
        }
        shape_count += 1;
    }

    try parser.expectObjectEnd();
    try parser.expectDocumentEnd();
    return shape_count;
}

const Parser = struct {
    arena: Allocator,
    reader: *std.json.Reader(std.json.default_buffer_size, std.io.AnyReader),

    pub fn expectObjectBegin(self: *Parser) !void {
        assert(.object_begin == try self.nextToken());
    }

    pub fn expectObjectEnd(self: *Parser) !void {
        assert(.object_end == try self.nextToken());
    }

    pub fn expectDocumentEnd(self: *Parser) !void {
        assert(.end_of_document == try self.nextToken());
    }

    pub fn expectString(self: *Parser, expectd: []const u8) !void {
        assert(std.mem.eql(u8, expectd, try self.nextString()));
    }

    pub fn nextShape(self: *Parser, name: []const u8) !void {
        try self.expectString("type");
        const shape_type = try self.nextString();
        std.log.debug("{s:<10} {s}", .{ shape_type, name });
        try self.skipObject();
    }

    pub fn skipObject(self: *Parser) !void {
        var indent: usize = 1;
        while (true) {
            switch (try self.nextToken()) {
                .object_begin, .array_begin => indent += 1,
                .array_end => indent -= 1,
                .object_end => {
                    indent -= 1;
                    if (indent == 0) break;
                },
                else => {},
            }
        }
    }

    pub fn nextString(self: *Parser) ![]const u8 {
        const token = try self.nextToken();
        switch (token) {
            .string, .allocated_string => |s| return s,
            else => unreachable,
        }
    }

    fn nextToken(self: *Parser) !std.json.Token {
        return try self.reader.nextAlloc(self.arena, .alloc_if_needed);
    }
};
