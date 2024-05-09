const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const smithy = @import("smithy");
const options = @import("options");
const whitelist: []const []const u8 = options.filter;
const models_path: []const u8 = options.models_path;
const install_path: []const u8 = options.install_path;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa_alloc = gpa.allocator();
    defer _ = gpa.deinit();

    var pipeline = try smithy.Pipeline.init(gpa_alloc, std.heap.page_allocator, .{
        .src_dir_absolute = models_path,
        .out_dir_relative = install_path,
        .parse_policy = .{ .property = .abort, .trait = .skip },
    }, .{}, null);
    defer pipeline.deinit();

    if (whitelist.len == 0) {
        _ = try pipeline.processAll(filterSourceModel);
    } else {
        var files = try std.ArrayList([]const u8).initCapacity(gpa_alloc, whitelist.len);
        defer {
            for (files.items) |file| {
                gpa_alloc.free(file);
            }
            files.deinit();
        }
        for (whitelist) |filename| {
            try files.append(try std.fmt.allocPrint(gpa_alloc, "{s}.json", .{filename}));
        }
        _ = try pipeline.processFiles(files.items);
    }
}

fn filterSourceModel(filename: []const u8) bool {
    return !std.mem.startsWith(u8, filename, "sdk-");
}
