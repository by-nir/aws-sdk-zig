const std = @import("std");
const fmt = std.fmt;
const ascii = std.ascii;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = std.testing.allocator;

const MutString = std.ArrayList(u8);

pub fn snakeCase(allocator: Allocator, value: []const u8) ![]const u8 {
    return fmt.allocPrint(allocator, "{s}", .{SnakeCase{ .value = value }});
}

pub const SnakeCase = struct {
    value: []const u8,

    pub fn format(self: SnakeCase, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        var retain = true;
        for (self.value) |c| {
            if (ascii.isLower(c) or c == '_') continue;
            retain = false;
            break;
        }
        if (retain) {
            try writer.writeAll(self.value);
            return;
        }

        var prev_upper = false;
        for (self.value, 0..) |c, i| {
            const is_upper = ascii.isUpper(c);
            try writer.writeByte(if (is_upper) blk: {
                if (!prev_upper and i > 0 and !isDivider(self.value[i - 1])) {
                    try writer.writeByte('_');
                }
                break :blk ascii.toLower(c);
            } else if (c == '-' or c == ' ') '_' else c);
            prev_upper = is_upper;
        }
    }
};

test "snakeCase" {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    try testing.expectEqualStrings("foo_bar", try snakeCase(arena_alloc, "foo-bar"));
    try testing.expectEqualStrings("foo_bar", try snakeCase(arena_alloc, "foo_bar"));
    try testing.expectEqualStrings("foo_bar", try snakeCase(arena_alloc, "fooBar"));
    try testing.expectEqualStrings("foo_bar", try snakeCase(arena_alloc, "FooBar"));
    try testing.expectEqualStrings("foo_bar", try snakeCase(arena_alloc, "FOO_BAR"));
}

pub fn screamCase(allocator: Allocator, value: []const u8) ![]const u8 {
    return fmt.allocPrint(allocator, "{s}", .{ScreamCase{ .value = value }});
}

pub const ScreamCase = struct {
    value: []const u8,

    pub fn format(self: ScreamCase, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        var retain = true;
        for (self.value) |c| {
            if (ascii.isUpper(c) or c == '_') continue;
            retain = false;
            break;
        }
        if (retain) {
            try writer.writeAll(self.value);
            return;
        }

        var prev_upper = false;
        for (self.value, 0..) |c, i| {
            const is_upper = ascii.isUpper(c);
            if (is_upper and !prev_upper and i > 0 and !isDivider(self.value[i - 1])) {
                try writer.writeByte('_');
            } else if (c == '-' or c == ' ') {
                try writer.writeByte('_');
                continue;
            }

            try writer.writeByte(if (is_upper) c else ascii.toUpper(c));
            prev_upper = is_upper;
        }
    }
};

test "screamCase" {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    try testing.expectEqualStrings("FOO_BAR", try screamCase(arena_alloc, "foo-bar"));
    try testing.expectEqualStrings("FOO_BAR", try screamCase(arena_alloc, "foo_bar"));
    try testing.expectEqualStrings("FOO_BAR", try screamCase(arena_alloc, "fooBar"));
    try testing.expectEqualStrings("FOO_BAR", try screamCase(arena_alloc, "FooBar"));
    try testing.expectEqualStrings("FOO_BAR", try screamCase(arena_alloc, "FOO_BAR"));
}

pub fn camelCase(allocator: Allocator, value: []const u8) ![]const u8 {
    return fmt.allocPrint(allocator, "{s}", .{CamelCase{ .value = value }});
}

pub const CamelCase = struct {
    value: []const u8,

    pub fn format(self: CamelCase, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        var prev_lower = false;
        var pending_upper = false;
        for (self.value) |c| {
            if (isDivider(c)) {
                pending_upper = true;
            } else if (pending_upper) {
                pending_upper = false;
                prev_lower = false;
                try writer.writeByte(ascii.toUpper(c));
            } else {
                const is_upper = ascii.isUpper(c);
                try writer.writeByte(if (is_upper and !prev_lower) ascii.toLower(c) else c);
                prev_lower = !is_upper;
            }
        }
    }
};

test "camelCase" {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    try testing.expectEqualStrings("fooBar", try camelCase(arena_alloc, "foo-bar"));
    try testing.expectEqualStrings("fooBar", try camelCase(arena_alloc, "foo_bar"));
    try testing.expectEqualStrings("fooBar", try camelCase(arena_alloc, "fooBar"));
    try testing.expectEqualStrings("fooBar", try camelCase(arena_alloc, "FooBar"));
    try testing.expectEqualStrings("fooBar", try camelCase(arena_alloc, "FOO_BAR"));
}

pub fn pascalCase(allocator: Allocator, value: []const u8) ![]const u8 {
    return fmt.allocPrint(allocator, "{s}", .{PascalCase{ .value = value }});
}

pub const PascalCase = struct {
    value: []const u8,

    pub fn format(self: PascalCase, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        var prev_lower = false;
        var pending_upper = true;
        for (self.value) |c| {
            if (isDivider(c)) {
                pending_upper = true;
            } else if (pending_upper) {
                pending_upper = false;
                prev_lower = false;
                try writer.writeByte(ascii.toUpper(c));
            } else {
                const is_upper = ascii.isUpper(c);
                try writer.writeByte(if (is_upper and !prev_lower) ascii.toLower(c) else c);
                prev_lower = !is_upper;
            }
        }
    }
};

test "pascalCase" {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    try testing.expectEqualStrings("FooBar", try pascalCase(arena_alloc, "foo-bar"));
    try testing.expectEqualStrings("FooBar", try pascalCase(arena_alloc, "foo_bar"));
    try testing.expectEqualStrings("FooBar", try pascalCase(arena_alloc, "fooBar"));
    try testing.expectEqualStrings("FooBar", try pascalCase(arena_alloc, "FooBar"));
    try testing.expectEqualStrings("FooBar", try pascalCase(arena_alloc, "FOO_BAR"));
}

pub fn titleCase(allocator: Allocator, value: []const u8) ![]const u8 {
    return fmt.allocPrint(allocator, "{s}", .{TitleCase{ .value = value }});
}

pub const TitleCase = struct {
    value: []const u8,

    pub fn format(self: TitleCase, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        var prev_upper = true;
        var pending_upper = true;
        for (self.value) |c| {
            if (!ascii.isAlphanumeric(c)) {
                if (!pending_upper) {
                    pending_upper = true;
                    try writer.writeByte(' ');
                }
                prev_upper = true;
            } else {
                const is_upper = ascii.isUpper(c);
                if (pending_upper and !is_upper) {
                    try writer.writeByte(ascii.toUpper(c));
                    prev_upper = true;
                } else if (is_upper and !prev_upper) {
                    try writer.print(" {c}", .{c});
                    prev_upper = true;
                } else if (!pending_upper and is_upper) {
                    try writer.writeByte(ascii.toLower(c));
                    prev_upper = true;
                } else {
                    try writer.writeByte(c);
                    prev_upper = is_upper;
                }
                pending_upper = false;
            }
        }
    }
};

test "titleCase" {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    try testing.expectEqualStrings("Foo Bar", try titleCase(arena_alloc, "foo-bar"));
    try testing.expectEqualStrings("Foo Bar", try titleCase(arena_alloc, "foo_bar"));
    try testing.expectEqualStrings("Foo Bar", try titleCase(arena_alloc, "fooBar"));
    try testing.expectEqualStrings("Foo Bar", try titleCase(arena_alloc, "FooBar"));
    try testing.expectEqualStrings("Foo Bar", try titleCase(arena_alloc, "FOO_BAR"));
    try testing.expectEqualStrings("Foo Bar", try titleCase(arena_alloc, "foo-+bar"));
}

fn isDivider(c: u8) bool {
    return switch (c) {
        '_', '-', ' ' => true,
        else => false,
    };
}
