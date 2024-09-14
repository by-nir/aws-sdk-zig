const std = @import("std");
const fmt = std.fmt;
const ascii = std.ascii;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = std.testing.allocator;

pub const Case = enum { snake, scream, camel, pascal, title };

pub fn formatCase(allocator: Allocator, comptime case: Case, value: []const u8) ![]const u8 {
    return fmt.allocPrint(allocator, "{s}", .{CaseFormatter(case){ .value = value }});
}

pub fn CaseFormatter(comptime case: Case) type {
    return switch (case) {
        .snake => SnakeCase,
        .scream => ScreamCase,
        .camel => CamelCase,
        .pascal => PascalCase,
        .title => TitleCase,
    };
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

test SnakeCase {
    try testing.expectFmt("foo_bar", "{s}", .{SnakeCase{ .value = "foo-bar" }});
    try testing.expectFmt("foo_bar", "{s}", .{SnakeCase{ .value = "foo_bar" }});
    try testing.expectFmt("foo_bar", "{s}", .{SnakeCase{ .value = "fooBar" }});
    try testing.expectFmt("foo_bar", "{s}", .{SnakeCase{ .value = "FooBar" }});
    try testing.expectFmt("foo_bar", "{s}", .{SnakeCase{ .value = "FOO_BAR" }});
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

test ScreamCase {
    try testing.expectFmt("FOO_BAR", "{s}", .{ScreamCase{ .value = "foo-bar" }});
    try testing.expectFmt("FOO_BAR", "{s}", .{ScreamCase{ .value = "foo_bar" }});
    try testing.expectFmt("FOO_BAR", "{s}", .{ScreamCase{ .value = "fooBar" }});
    try testing.expectFmt("FOO_BAR", "{s}", .{ScreamCase{ .value = "FooBar" }});
    try testing.expectFmt("FOO_BAR", "{s}", .{ScreamCase{ .value = "FOO_BAR" }});
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

test CamelCase {
    try testing.expectFmt("fooBar", "{s}", .{CamelCase{ .value = "foo-bar" }});
    try testing.expectFmt("fooBar", "{s}", .{CamelCase{ .value = "foo_bar" }});
    try testing.expectFmt("fooBar", "{s}", .{CamelCase{ .value = "fooBar" }});
    try testing.expectFmt("fooBar", "{s}", .{CamelCase{ .value = "FooBar" }});
    try testing.expectFmt("fooBar", "{s}", .{CamelCase{ .value = "FOO_BAR" }});
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

test PascalCase {
    try testing.expectFmt("FooBar", "{s}", .{PascalCase{ .value = "foo-bar" }});
    try testing.expectFmt("FooBar", "{s}", .{PascalCase{ .value = "foo_bar" }});
    try testing.expectFmt("FooBar", "{s}", .{PascalCase{ .value = "fooBar" }});
    try testing.expectFmt("FooBar", "{s}", .{PascalCase{ .value = "FooBar" }});
    try testing.expectFmt("FooBar", "{s}", .{PascalCase{ .value = "FOO_BAR" }});
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

test TitleCase {
    try testing.expectFmt("Foo Bar", "{s}", .{TitleCase{ .value = "foo-bar" }});
    try testing.expectFmt("Foo Bar", "{s}", .{TitleCase{ .value = "foo_bar" }});
    try testing.expectFmt("Foo Bar", "{s}", .{TitleCase{ .value = "fooBar" }});
    try testing.expectFmt("Foo Bar", "{s}", .{TitleCase{ .value = "FooBar" }});
    try testing.expectFmt("Foo Bar", "{s}", .{TitleCase{ .value = "FOO_BAR" }});
    try testing.expectFmt("Foo Bar", "{s}", .{TitleCase{ .value = "foo-+bar" }});
}

fn isDivider(c: u8) bool {
    return switch (c) {
        '_', '-', ' ' => true,
        else => false,
    };
}
