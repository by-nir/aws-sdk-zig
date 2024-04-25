const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const options = @import("options");
const filter: []const []const u8 = options.filter;
const models_path: []const u8 = options.models_path;
const install_path: []const u8 = options.install_path;
const smithy = @import("smithy");
const IssuesBag = smithy.IssuesBag;
const JsonReader = smithy.JsonReader;
const TraitsManager = smithy.TraitsManager;

pub const Stats = struct { shapes: usize, duration_ns: u64 };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var traits_manager = TraitsManager{};
    defer {
        traits_manager.deinit(gpa.allocator());
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

    const output_alloc = output_arena.allocator();
    if (filter.len > 0) {
        // Process filtered models
        const input_alloc = input_arena.allocator();
        for (filter) |model_path| {
            defer _ = input_arena.reset(.retain_capacity);
            const filename = try std.fmt.allocPrint(input_alloc, "{s}.json", .{model_path});
            const file = try openFile(models_dir, filename);
            defer file.close();

            var reader = try JsonReader.initFile(input_arena.allocator(), file);
            var issues = IssuesBag.init(output_alloc);
            defer {
                reader.deinit();
                issues.deinit();
            }

            if (processModelFile(
                output_alloc,
                traits_manager,
                filename,
                &issues,
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

            var issues = IssuesBag.init(output_alloc);
            var reader = JsonReader.init(input_arena.allocator(), file.reader().any());
            defer {
                _ = input_arena.reset(.retain_capacity);
                issues.deinit();
                reader.deinit();
            }

            if (processModelFile(
                output_alloc,
                traits_manager,
                entry.name,
                &issues,
                &reader,
            )) |stats| {
                models_len += 1;
                shapes_len += stats.shapes;
                duration += stats.duration_ns;
            }
        }
    }

    // TODO: Move this to a utility function of Smithy
    const secs = @as(f64, @floatFromInt(duration)) / std.time.ns_per_s;
    std.log.info("\n\n" ++
        \\╭─ AWS SDK CodeGen ──── {d:.2}s ─╮
        \\│                              │
        \\│  Services                 ?  │
        \\│  Resources                ?  │
        \\│  Operations               ?  │
        \\│                              │
        \\├─ Parsed ─────────── (skips) ─┤
        \\│                              │
        \\│  Models               ? (?)  │
        \\│  Meta items           ? (?)  │
        \\│  Shapes               ? (?)  │
        \\│  Members              ? (?)  │
        \\│  Traits               ? (?)  │
        \\│                              │
        \\╰──────────────────────────────╯
        \\
    , .{secs});
}

fn openFile(models_dir: fs.Dir, filename: []const u8) !fs.File {
    return models_dir.openFile(filename, .{}) catch |e| {
        std.log.warn("Failed opening model `{s}`: {s}.", .{ filename, @errorName(e) });
        return e;
    };
}

fn processModelFile(
    arena: Allocator,
    traits_manager: TraitsManager,
    name: []const u8,
    issues: *IssuesBag,
    reader: *JsonReader,
) ?Stats {
    std.log.info("Start processing model {s}", .{name});
    var timer = std.time.Timer.start() catch unreachable;
    if (smithy.parseJson(
        arena,
        traits_manager,
        .{ .property = .abort, .trait = .skip },
        issues,
        reader,
    )) |model| {
        return .{ .shapes = model.shapes.size, .duration_ns = timer.read() };
    } else |e| {
        switch (e) {
            error.AbortPolicy => {},
            else => |err| issues.add(.{ .parse_model_error = @errorName(err) }) catch unreachable,
        }
        return null;
    }
}
