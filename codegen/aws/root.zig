const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const options = @import("options");
const filter: []const []const u8 = options.filter;
const models_path: []const u8 = options.models_path;
const install_path: []const u8 = options.install_path;
const smithy = @import("smithy");
const JsonReader = smithy.JsonReader;
const TraitManager = smithy.TraitManager;

pub const Stats = struct { shapes: usize, duration_ns: u64 };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var manager = TraitManager{};
    defer {
        manager.deinit(gpa.allocator());
        _ = gpa.deinit();
    }

    var input_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var output_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer _ = output_arena.deinit();

    var models_dir = try fs.openDirAbsolute(models_path, .{
        .iterate = true,
        .access_sub_paths = true,
    });
    defer models_dir.close();

    var models_len: usize = 0;
    var shapes_len: usize = 0;
    var duration: u64 = 0;

    const input_alloc = input_arena.allocator();
    if (filter.len > 0) {
        // Process filtered models
        for (filter) |model_path| {
            defer _ = input_arena.reset(.retain_capacity);
            const filename = try std.fmt.allocPrint(input_alloc, "{s}.json", .{model_path});
            const file = try openFile(models_dir, filename);
            defer file.close();

            var reader = JsonReader.init(input_arena.allocator(), file.reader().any());
            defer reader.deinit();

            if (processModelFile(
                output_arena.allocator(),
                manager,
                filename,
                &reader,
            )) |stats| {
                models_len += 1;
                shapes_len += stats.shapes;
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
            const file = try openFile(models_dir, entry.name);
            defer file.close();

            var reader = JsonReader.init(input_arena.allocator(), file.reader().any());
            defer {
                _ = input_arena.reset(.retain_capacity);
                reader.deinit();
            }

            if (processModelFile(
                output_arena.allocator(),
                manager,
                entry.name,
                &reader,
            )) |stats| {
                models_len += 1;
                shapes_len += stats.shapes;
                duration += stats.duration_ns;
            }
        }
    }

    const secs = @as(f64, @floatFromInt(duration)) / std.time.ns_per_s;
    const suffix = if (models_len == 1) " " else "s";
    std.log.info("\n\n" ++
        \\╭─ SDK CodeGen ───── {d:.2} sec ─╮
        \\│                              │
        \\│  Service{s} {d:17}  │
        \\│  Shapes {d:19}  │
        \\│                              │
        \\╰──────────────────────────────╯
    ++ "\n", .{ secs, suffix, models_len, shapes_len });
}

fn openFile(models_dir: fs.Dir, filename: []const u8) !fs.File {
    return models_dir.openFile(filename, .{}) catch |e| {
        std.log.warn("Failed opening model `{s}`: {s}.", .{ filename, @errorName(e) });
        return e;
    };
}

fn processModelFile(arena: Allocator, manager: TraitManager, name: []const u8, reader: *JsonReader) ?Stats {
    std.log.info("Start processing model {s}", .{name});
    const start = std.time.Instant.now() catch unreachable;
    const model = smithy.parseJson(arena, reader, manager) catch |e| {
        std.log.err(
            "Failed processing model `{s}`: {s}.{any}\n",
            .{ name, @errorName(e), @errorReturnTrace() },
        );
        return null;
    };
    const end = std.time.Instant.now() catch unreachable;

    return .{ .shapes = model.shapes.size, .duration_ns = end.since(start) };
}
