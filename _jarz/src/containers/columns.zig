const std = @import("std");
const meta = std.meta;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const AutoSlots = @import("slots.zig").AutoSlots;
const DefaultIndexer = @import("../interface/common.zig").DefaultIndexer;

pub const ColumnsOptions = struct {
    Indexer: type = DefaultIndexer,
};

pub fn ColumnsViewer(comptime Indexer: type, comptime T: type) type {
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

pub fn Columns(comptime T: type, comptime options: ColumnsOptions) type {
    return struct {
        const Self = @This();
        pub const Viewer = ColumnsViewer(options.Indexer, T);

        columns: std.MultiArrayList(T).Slice,

        pub fn deinit(self: Self, allocator: Allocator) void {
            var cols = self.columns.toMultiArrayList();
            cols.deinit(allocator);
        }

        pub fn view(self: Self) Viewer {
            return .{ .multi = self.columns };
        }
    };
}

test "Columns" {
    const cols = blk: {
        var multilist = std.MultiArrayList(Vec3){};
        errdefer multilist.deinit(test_alloc);

        try multilist.append(test_alloc, .{ .x = 1, .y = 2, .z = 3 });
        try multilist.append(test_alloc, .{ .x = 7, .y = 8, .z = 9 });

        break :blk Columns(Vec3, .{}){ .columns = multilist.toOwnedSlice() };
    };
    defer cols.deinit(test_alloc);

    try testing.expectEqual(2, cols.view().peekField(0, .y));
    try testing.expectEqualSlices(i32, &.{ 2, 8 }, cols.view().peekColumn(.y));
    try testing.expectEqualDeep(Vec3{ .x = 1, .y = 2, .z = 3 }, cols.view().peekItem(0));
}

/// Columnar storage
pub fn MutableColumns(comptime T: type, comptime options: ColumnsOptions) type {
    return struct {
        const Self = @This();
        const Idx = options.Indexer;
        const Column: type = meta.FieldEnum(T);
        pub const Viewer = ColumnsViewer(Idx, T);

        columns: std.MultiArrayList(T) = .{},
        gaps: AutoSlots(Idx) = .{},

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.columns.deinit(allocator);
            self.gaps.deinit(allocator);
        }

        /// The caller owns the returned memory. Clears the columns document.
        pub fn toReadOnly(self: *Self) Columns(T, options) {
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

        pub fn view(self: Self) Viewer {
            return .{ .multi = self.columns.slice() };
        }
    };
}

test "MutableColumns" {
    var cols = MutableColumns(Vec3, .{}){};
    defer cols.deinit(test_alloc);

    const t0 = try cols.claimItem(test_alloc, Vec3.zero);
    try testing.expectEqual(0, cols.view().peekField(t0, .y));
    try testing.expectEqualDeep(Vec3.zero, cols.view().peekItem(t0));

    const t1 = try cols.claimItem(test_alloc, .{ .x = 1, .y = 2, .z = 3 });
    try testing.expectEqual(2, cols.view().peekField(t1, .y));
    try testing.expectEqualDeep(Vec3{ .x = 1, .y = 2, .z = 3 }, cols.view().peekItem(t1));

    cols.releaseItem(test_alloc, t1);
    try testing.expectEqual(t1, try cols.claimItem(test_alloc, Vec3.zero));
    try testing.expectEqual(0, cols.view().peekField(t1, .y));

    cols.setField(t1, .y, 8);
    try testing.expectEqual(8, cols.view().peekField(t1, .y));

    const field = cols.refField(t1, .y);
    try testing.expectEqual(8, field.*);
    field.* = 9;
    try testing.expectEqual(9, cols.view().peekField(t1, .y));

    cols.setItem(t1, .{ .x = 2, .y = 4, .z = 6 });
    try testing.expectEqualDeep(Vec3{ .x = 2, .y = 4, .z = 6 }, cols.view().peekItem(t1));

    try testing.expectEqualSlices(i32, &.{ 0, 4 }, cols.view().peekColumn(.y));
}

test "MutableColumns: consume" {
    const cols = blk: {
        var mut = MutableColumns(Vec3, .{}){};
        errdefer mut.deinit(test_alloc);

        _ = try mut.claimItem(test_alloc, .{ .x = 1, .y = 2, .z = 3 });
        _ = try mut.claimItem(test_alloc, .{ .x = 7, .y = 8, .z = 9 });

        break :blk mut.toReadOnly();
    };
    defer cols.deinit(test_alloc);

    try testing.expectEqualSlices(i32, &.{ 1, 7 }, cols.view().peekColumn(.x));
    try testing.expectEqualSlices(i32, &.{ 2, 8 }, cols.view().peekColumn(.y));
    try testing.expectEqualSlices(i32, &.{ 3, 9 }, cols.view().peekColumn(.z));
}

const Vec3 = struct {
    x: i32,
    y: i32,
    z: i32,

    pub const zero = Vec3{ .x = 0, .y = 0, .z = 0 };
};
