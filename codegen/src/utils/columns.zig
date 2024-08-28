const std = @import("std");
const meta = std.meta;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const AutoSlots = @import("slots.zig").AutoSlots;
const DefaultIndexer = @import("common.zig").DefaultIndexer;

pub const ColumnsOptions = struct {
    Indexer: type = DefaultIndexer,
};

pub fn ColumnsQuery(comptime Indexer: type, comptime T: type) type {
    const Column: type = meta.FieldEnum(T);
    const MultiSlice = std.MultiArrayList(T).Slice;

    return struct {
        const Self = @This();

        multi: MultiSlice,

        pub inline fn peekItem(self: Self, i: Indexer) T {
            return self.multi.get(i);
        }

        pub inline fn peekField(self: Self, i: Indexer, comptime column: Column) meta.FieldType(T, column) {
            return self.multi.items(column)[i];
        }

        pub inline fn peekColumn(self: Self, comptime column: Column) []const meta.FieldType(T, column) {
            return self.multi.items(column);
        }
    };
}

pub fn ReadOnlyColumns(comptime T: type, comptime options: ColumnsOptions) type {
    return struct {
        const Self = @This();
        const Idx = options.Indexer;
        pub const Query = ColumnsQuery(Idx, T);

        columns: std.MultiArrayList(T).Slice,

        pub fn deinit(self: Self, allocator: Allocator) void {
            var cols = self.columns.toMultiArrayList();
            cols.deinit(allocator);
        }

        pub fn query(self: Self) Query {
            return .{ .multi = self.columns };
        }
    };
}

test "ReadOnlyolumns" {
    const cols = blk: {
        var multilist = std.MultiArrayList(Vec3){};
        errdefer multilist.deinit(test_alloc);

        try multilist.append(test_alloc, .{ .x = 1, .y = 2, .z = 3 });
        try multilist.append(test_alloc, .{ .x = 7, .y = 8, .z = 9 });

        break :blk ReadOnlyColumns(Vec3, .{}){ .columns = multilist.toOwnedSlice() };
    };
    defer cols.deinit(test_alloc);

    try testing.expectEqual(2, cols.query().peekField(0, .y));
    try testing.expectEqualSlices(i32, &.{ 2, 8 }, cols.query().peekColumn(.y));
    try testing.expectEqualDeep(Vec3{ .x = 1, .y = 2, .z = 3 }, cols.query().peekItem(0));
}

/// Columnar storage
pub fn MutableColumns(comptime T: type, comptime options: ColumnsOptions) type {
    return struct {
        const Self = @This();
        const Idx = options.Indexer;
        const Column: type = meta.FieldEnum(T);
        pub const Query = ColumnsQuery(Idx, T);

        columns: std.MultiArrayList(T) = .{},
        gaps: AutoSlots(Idx) = .{},

        /// Do not call if already consumed.
        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.columns.deinit(allocator);
            self.gaps.deinit(allocator);
        }

        /// No need to call deinit after consuming.
        pub fn consume(self: *Self) ReadOnlyColumns(T, options) {
            return .{ .columns = self.columns.toOwnedSlice() };
        }

        pub fn claimItem(self: *Self, allocator: Allocator, item: T) !Idx {
            if (self.gaps.takeLast()) |gap| {
                errdefer self.gaps.put(allocator, gap) catch {};
                self.columns.set(gap, item);
                return @intCast(gap);
            } else {
                const i = self.columns.len;
                assert(self.columns.len < std.math.maxInt(Idx));
                try self.columns.append(allocator, item);
                return @intCast(i);
            }
        }

        pub fn releaseItem(self: *Self, allocator: Allocator, item: Idx) void {
            if (self.columns.len == item + 1) {
                _ = self.columns.pop();
            } else {
                if (std.debug.runtime_safety) self.columns.set(item, undefined);
                self.gaps.put(allocator, item) catch {};
            }
        }

        pub fn setItem(self: *Self, i: Idx, item: T) void {
            self.columns.set(i, item);
        }

        pub fn setField(self: *Self, i: Idx, comptime column: Column, value: meta.FieldType(T, column)) void {
            self.columns.items(column)[i] = value;
        }

        pub fn refField(self: *Self, i: Idx, comptime column: Column) *meta.FieldType(T, column) {
            return &self.columns.items(column)[i];
        }

        pub fn query(self: Self) Query {
            return .{ .multi = self.columns.slice() };
        }
    };
}

test "MutableColumns" {
    var cols = MutableColumns(Vec3, .{}){};
    defer cols.deinit(test_alloc);

    const t0 = try cols.claimItem(test_alloc, Vec3.zero);
    try testing.expectEqual(0, cols.query().peekField(t0, .y));
    try testing.expectEqualDeep(Vec3.zero, cols.query().peekItem(t0));

    const t1 = try cols.claimItem(test_alloc, .{ .x = 1, .y = 2, .z = 3 });
    try testing.expectEqual(2, cols.query().peekField(t1, .y));
    try testing.expectEqualDeep(Vec3{ .x = 1, .y = 2, .z = 3 }, cols.query().peekItem(t1));

    cols.releaseItem(test_alloc, t1);
    try testing.expectEqual(t1, try cols.claimItem(test_alloc, Vec3.zero));
    try testing.expectEqual(0, cols.query().peekField(t1, .y));

    cols.setField(t1, .y, 8);
    try testing.expectEqual(8, cols.query().peekField(t1, .y));

    const field = cols.refField(t1, .y);
    try testing.expectEqual(8, field.*);
    field.* = 9;
    try testing.expectEqual(9, cols.query().peekField(t1, .y));

    cols.setItem(t1, .{ .x = 2, .y = 4, .z = 6 });
    try testing.expectEqualDeep(Vec3{ .x = 2, .y = 4, .z = 6 }, cols.query().peekItem(t1));

    try testing.expectEqualSlices(i32, &.{ 0, 4 }, cols.query().peekColumn(.y));
}

test "MutableColumns: consume" {
    const cols = blk: {
        var mut = MutableColumns(Vec3, .{}){};
        errdefer mut.deinit(test_alloc);

        _ = try mut.claimItem(test_alloc, .{ .x = 1, .y = 2, .z = 3 });
        _ = try mut.claimItem(test_alloc, .{ .x = 7, .y = 8, .z = 9 });

        break :blk mut.consume();
    };
    defer cols.deinit(test_alloc);

    try testing.expectEqualSlices(i32, &.{ 1, 7 }, cols.query().peekColumn(.x));
    try testing.expectEqualSlices(i32, &.{ 2, 8 }, cols.query().peekColumn(.y));
    try testing.expectEqualSlices(i32, &.{ 3, 9 }, cols.query().peekColumn(.z));
}

const Vec3 = struct {
    x: i32,
    y: i32,
    z: i32,

    pub const zero = Vec3{ .x = 0, .y = 0, .z = 0 };
};
