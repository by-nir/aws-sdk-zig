const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;

const Self = @This();

pub const PolicyResolution = enum { skip, abort };
pub const PolicyAbortError = error.PolicyAbort;

pub const Issue = union(enum) {
    parse_error: anyerror,
    parse_unexpected_prop: Names,
    parse_unknown_trait: Names,
    codegen_error: anyerror,
    codegen_unknown_shape: Id,
    codegen_invalid_root: NameOrId,
    codegen_shape_fail: NamedError,
    readme_error: anyerror,
    process_error: anyerror,

    pub const Id = u32;

    pub const Names = struct {
        context: []const u8,
        item: []const u8,
    };

    pub const NameOrId = union(enum) {
        name: []const u8,
        id: Id,
    };

    pub const NamedError = struct {
        item: NameOrId,
        err: anyerror,
    };
};

pub const Stats = struct {
    parse_error: u16 = 0,
    parse_unexpected_prop: u16 = 0,
    parse_unknown_trait: u16 = 0,
    codegen_error: u16 = 0,
    codegen_unknown_shape: u16 = 0,
    codegen_invalid_root: u16 = 0,
    codegen_shape_fail: u16 = 0,
    readme_error: u16 = 0,
    process_error: u16 = 0,

    pub fn parseCount(self: Stats) usize {
        return self.parse_error + self.parse_unexpected_prop + self.parse_unknown_trait;
    }

    pub fn codegenCount(self: Stats) usize {
        return self.codegen_error + self.codegen_unknown_shape + self.codegen_invalid_root + self.codegen_shape_fail;
    }
};

allocator: Allocator,
stats: Stats = .{},
list: std.ArrayListUnmanaged(Issue) = .{},

pub fn init(allocator: Allocator) Self {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Self) void {
    for (self.list.items) |issue| {
        switch (issue) {
            .parse_unexpected_prop, .parse_unknown_trait => |t| {
                self.allocator.free(t.context);
                self.allocator.free(t.item);
            },
            .codegen_invalid_root => |t| switch (t) {
                .name => |name| self.allocator.free(name),
                else => {},
            },
            .codegen_shape_fail => |t| switch (t.item) {
                .name => |name| self.allocator.free(name),
                else => {},
            },
            else => {},
        }
    }
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
            const item = try self.allocator.dupe(u8, t.item);
            errdefer self.allocator.free(item);
            const dup = Issue.Names{ .context = context, .item = item };
            try self.list.append(
                self.allocator,
                @unionInit(Issue, @tagName(g), dup),
            );
            @field(self.stats, @tagName(g)) += 1;
        },
        .codegen_invalid_root => |t| {
            switch (t) {
                .name => |name| {
                    const dup = try self.allocator.dupe(u8, name);
                    errdefer self.allocator.free(dup);
                    try self.list.append(
                        self.allocator,
                        .{ .codegen_invalid_root = .{ .name = dup } },
                    );
                },
                else => try self.list.append(self.allocator, issue),
            }
            self.stats.codegen_invalid_root += 1;
        },
        .codegen_shape_fail => |t| {
            switch (t.item) {
                .name => |name| {
                    const dup = try self.allocator.dupe(u8, name);
                    errdefer self.allocator.free(dup);
                    try self.list.append(
                        self.allocator,
                        .{ .codegen_shape_fail = .{
                            .err = t.err,
                            .item = .{ .name = dup },
                        } },
                    );
                },
                else => try self.list.append(self.allocator, issue),
            }
            self.stats.codegen_shape_fail += 1;
        },
        inline else => |_, g| {
            try self.list.append(self.allocator, issue);
            @field(self.stats, @tagName(g)) += 1;
        },
    }
}

test "IssuesBag" {
    var bag = Self.init(test_alloc);
    defer bag.deinit();

    try bag.add(.{ .parse_error = error.ParseError });
    try bag.add(.{ .parse_unexpected_prop = .{ .context = "foo", .item = "bar" } });
    try bag.add(.{ .parse_unknown_trait = .{ .context = "baz", .item = "qux" } });
    try bag.add(.{ .codegen_error = error.CodegenError });
    try bag.add(.{ .codegen_unknown_shape = 108 });
    try bag.add(.{ .codegen_invalid_root = .{ .name = "foo" } });
    try bag.add(.{ .codegen_shape_fail = .{
        .err = error.ShapeError,
        .item = .{ .name = "bar" },
    } });
    try bag.add(.{ .readme_error = error.ReadmeError });
    try bag.add(.{ .process_error = error.ProcessError });

    try testing.expectEqual(9, bag.count());
    try testing.expectEqual(3, bag.stats.parseCount());
    try testing.expectEqual(1, bag.stats.parse_error);
    try testing.expectEqual(1, bag.stats.parse_unexpected_prop);
    try testing.expectEqual(1, bag.stats.parse_unknown_trait);
    try testing.expectEqual(4, bag.stats.codegenCount());
    try testing.expectEqual(1, bag.stats.codegen_error);
    try testing.expectEqual(1, bag.stats.codegen_unknown_shape);
    try testing.expectEqual(1, bag.stats.codegen_invalid_root);
    try testing.expectEqual(1, bag.stats.codegen_shape_fail);
    try testing.expectEqual(1, bag.stats.readme_error);
    try testing.expectEqual(1, bag.stats.process_error);

    try testing.expectEqualDeep(&[_]Issue{
        .{ .parse_error = error.ParseError },
        .{ .parse_unexpected_prop = .{ .context = "foo", .item = "bar" } },
        .{ .parse_unknown_trait = .{ .context = "baz", .item = "qux" } },
        .{ .codegen_error = error.CodegenError },
        .{ .codegen_unknown_shape = 108 },
        .{ .codegen_invalid_root = .{ .name = "foo" } },
        .{ .codegen_shape_fail = .{
            .err = error.ShapeError,
            .item = .{ .name = "bar" },
        } },
        .{ .readme_error = error.ReadmeError },
        .{ .process_error = error.ProcessError },
    }, bag.all());
}
