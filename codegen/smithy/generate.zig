//! Produces Zig source code from a Smithy model.
//!
//! The following codebase is generated for a Smithy model:
//! - `<service_name>/`
//!   - `README.md`
//!   - `root.zig`
const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const SmithyId = @import("symbols/identity.zig").SmithyId;

/// Must `close()` the returned directory when complete.
pub fn getModelDir(rel_base: []const u8, rel_model: []const u8) !fs.Dir {
    var raw_path: [128]u8 = undefined;
    @memcpy(raw_path[0..rel_base.len], rel_base);
    raw_path[rel_base] = '/';

    @memcpy(raw_path[rel_base.len + 1 ..][0..rel_model.len], rel_model);
    const path = raw_path[0 .. rel_base.len + 1 + rel_model.len];

    return fs.cwd().openDir(path, .{}) catch |e| switch (e) {
        error.FileNotFound => try fs.cwd().makeOpenPath(path, .{}),
        else => return e,
    };
}

pub fn generateModel(allocator: Allocator, name: []const u8, model: SmithyModel) !void {
}

pub const ReadmeSlots = struct {
    /// `{[title]s}` service title
    title: []const u8,
    /// `{[slug]s}` service SDK ID
    slug: []const u8,
};

/// Optionaly add any (or none) of the ReadmeSlots to the template. Each specifier
/// may appear more then once or not at all.
fn writeReadme(allocator: Allocator, comptime template: []const u8, slots: ReadmeSlots) ![]const u8 {
    return std.fmt.allocPrint(allocator, template, slots);
}

test "writeReadme" {
    const template = @embedFile("tests/README.md.template");
    const slots = ReadmeSlots{ .title = "Foo Bar", .slug = "foo-bar" };
    const output = try writeReadme(test_alloc, template, slots);
    defer test_alloc.free(output);
    try testing.expectEqualStrings(
        \\# Generated Foo Bar Service
        \\Learn more – [user guide](https://example.com/foo-bar)
    , output);
}

