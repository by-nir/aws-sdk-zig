const std = @import("std");
const ascii = std.ascii;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = std.testing.allocator;

pub fn snakeCase(arena: Allocator, input: []const u8) ![]const u8 {
    var retain = true;
    for (input) |c| {
        if (ascii.isUpper(c)) retain = false;
    }
    if (retain) {
        if (std.zig.Token.keywords.has(input))
            return std.fmt.allocPrint(arena, "@\"{s}\"", .{input})
        else
            return input;
    }

    var buffer = try std.ArrayList(u8).initCapacity(arena, input.len);
    errdefer buffer.deinit();

    var prev_upper = false;
    for (input, 0..) |c, i| {
        const is_upper = ascii.isUpper(c);
        try buffer.append(if (is_upper) blk: {
            if (!prev_upper and i > 0 and input[i - 1] != '_') {
                try buffer.append('_');
            }
            break :blk ascii.toLower(c);
        } else c);
        prev_upper = is_upper;
    }

    if (std.zig.Token.keywords.has(buffer.items)) {
        try buffer.insertSlice(0, "@\"");
        try buffer.append('"');
    }
    return try buffer.toOwnedSlice();
}

test "snakeCase" {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    try testing.expectEqualStrings("foo_bar", try snakeCase(arena_alloc, "foo_bar"));
    try testing.expectEqualStrings("foo_bar", try snakeCase(arena_alloc, "fooBar"));
    try testing.expectEqualStrings("foo_bar", try snakeCase(arena_alloc, "FooBar"));
    try testing.expectEqualStrings("foo_bar", try snakeCase(arena_alloc, "FOO_BAR"));
    try testing.expectEqualStrings("@\"error\"", try snakeCase(arena_alloc, "error"));
}

pub fn camelCase(arena: Allocator, input: []const u8) ![]const u8 {
    var buffer = try std.ArrayList(u8).initCapacity(arena, input.len);
    errdefer buffer.deinit();

    var prev_lower = false;
    var pending_upper = false;
    for (input) |c| {
        if (c == '_') {
            pending_upper = true;
        } else if (pending_upper) {
            pending_upper = false;
            prev_lower = false;
            try buffer.append(ascii.toUpper(c));
        } else {
            const is_upper = ascii.isUpper(c);
            try buffer.append(if (is_upper and !prev_lower) ascii.toLower(c) else c);
            prev_lower = !is_upper;
        }
    }

    if (std.zig.Token.keywords.has(buffer.items)) {
        try buffer.insertSlice(0, "@\"");
        try buffer.append('"');
    }
    return try buffer.toOwnedSlice();
}

test "camelCase" {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    try testing.expectEqualStrings("fooBar", try camelCase(arena_alloc, "foo_bar"));
    try testing.expectEqualStrings("fooBar", try camelCase(arena_alloc, "fooBar"));
    try testing.expectEqualStrings("fooBar", try camelCase(arena_alloc, "FooBar"));
    try testing.expectEqualStrings("fooBar", try camelCase(arena_alloc, "FOO_BAR"));
    try testing.expectEqualStrings("@\"error\"", try camelCase(arena_alloc, "error"));
}

pub fn titleCase(arena: Allocator, input: []const u8) ![]const u8 {
    var buffer = try std.ArrayList(u8).initCapacity(arena, input.len);
    errdefer buffer.deinit();

    var prev_upper = true;
    var pending_upper = true;
    for (input) |c| {
        if (!ascii.isAlphanumeric(c)) {
            if (!pending_upper) {
                pending_upper = true;
                try buffer.append(' ');
            }
            prev_upper = true;
        } else {
            const is_upper = ascii.isUpper(c);
            if (pending_upper and !is_upper) {
                try buffer.append(ascii.toUpper(c));
                prev_upper = true;
            } else if (is_upper and !prev_upper) {
                try buffer.appendSlice(&.{ ' ', c });
                prev_upper = true;
            } else if (!pending_upper and is_upper) {
                try buffer.append(ascii.toLower(c));
                prev_upper = true;
            } else {
                try buffer.append(c);
                prev_upper = is_upper;
            }
            pending_upper = false;
        }
    }

    return try buffer.toOwnedSlice();
}

test "titleCase" {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    try testing.expectEqualStrings("Foo Bar", try titleCase(arena_alloc, "foo_bar"));
    try testing.expectEqualStrings("Foo Bar", try titleCase(arena_alloc, "fooBar"));
    try testing.expectEqualStrings("Foo Bar", try titleCase(arena_alloc, "FooBar"));
    try testing.expectEqualStrings("Foo Bar", try titleCase(arena_alloc, "FOO_BAR"));
    try testing.expectEqualStrings("Foo Bar", try titleCase(arena_alloc, "foo-bar"));
    try testing.expectEqualStrings("Foo Bar", try titleCase(arena_alloc, "foo-+bar"));
}
