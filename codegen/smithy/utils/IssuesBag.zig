const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;

const Self = @This();

pub const Issue = union(enum) {
    parse_model_error: []const u8,
    parse_unexpected_prop: ParseIssue,
    parse_unknown_trait: ParseIssue,
};

pub const ParseIssue = struct {
    context: []const u8,
    name: []const u8,
};

pub const Stats = struct {
    parse_model_error: u16 = 0,
    parse_unexpected_prop: u16 = 0,
    parse_unknown_trait: u16 = 0,

    pub fn countParsing(self: Stats) usize {
        return self.parse_model_error + self.parse_unexpected_prop + self.parse_unknown_trait;
    }
};

allocator: Allocator,
stats: Stats = .{},
list: std.ArrayListUnmanaged(Issue) = .{},

pub fn init(allocator: Allocator) Self {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Self) void {
    for (self.list.items) |issue| switch (issue) {
        .parse_unexpected_prop, .parse_unknown_trait => |t| {
            self.allocator.free(t.context);
            self.allocator.free(t.name);
        },
        else => {},
    };
    self.list.deinit(self.allocator);
}

pub fn count(self: Self) usize {
    return self.list.items.len;
}

pub fn all(self: Self) []const Issue {
    return self.list.items;
}

pub fn add(self: *Self, issue: Issue) !void {
    switch (issue) {
        inline .parse_unexpected_prop, .parse_unknown_trait => |t, g| {
            const context = try self.allocator.dupe(u8, t.context);
            errdefer self.allocator.free(context);
            const name = try self.allocator.dupe(u8, t.name);
            errdefer self.allocator.free(name);
            const dup = ParseIssue{ .context = context, .name = name };
            try self.list.append(
                self.allocator,
                @unionInit(Issue, @tagName(g), dup),
            );
            @field(self.stats, @tagName(g)) += 1;
        },
        inline else => |_, g| {
            try self.list.append(self.allocator, issue);
            @field(self.stats, @tagName(g)) += 1;
        },
    }
}

test "standard usage" {
    var bag = Self.init(test_alloc);
    defer bag.deinit();

    try bag.add(.{ .parse_model_error = "FooError" });
    try bag.add(.{ .parse_unexpected_prop = .{ .context = "foo", .name = "bar" } });
    try bag.add(.{ .parse_unknown_trait = .{ .context = "baz", .name = "qux" } });

    try testing.expectEqual(3, bag.count());
    try testing.expectEqual(3, bag.stats.countParsing());
    try testing.expectEqual(1, bag.stats.parse_model_error);
    try testing.expectEqual(1, bag.stats.parse_unexpected_prop);
    try testing.expectEqual(1, bag.stats.parse_unknown_trait);
    try testing.expectEqualDeep(&[_]Issue{
        .{ .parse_model_error = "FooError" },
        .{ .parse_unexpected_prop = .{ .context = "foo", .name = "bar" } },
        .{ .parse_unknown_trait = .{ .context = "baz", .name = "qux" } },
    }, bag.all());
}
