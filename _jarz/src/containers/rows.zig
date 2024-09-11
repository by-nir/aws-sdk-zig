const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;
const test_alloc = testing.allocator;
const AutoSlots = @import("slots.zig").AutoSlots;
const iter = @import("../interface/iterate.zig");
const Reorder = @import("../interface/common.zig").Reorder;
const DefaultIndexer = @import("../interface/common.zig").DefaultIndexer;

pub fn RowsOptions(comptime T: type) type {
    return struct {
        Indexer: type = DefaultIndexer,
        equalFn: ?fn (a: T, b: T) bool = null,
    };
}

fn RowRecord(comptime Idx: type) type {
    return packed struct {
        offset: u32,
        len: Idx,

        pub const byte_len = @divExact(@bitSizeOf(@This()), 8);
    };
}

pub fn Rows(comptime T: type, comptime options: RowsOptions(T)) type {
    const Idx = options.Indexer;
    const Record = RowRecord(Idx);
    const utils = RowsUtils(T, options);

    return struct {
        const Self = @This();
        pub const Viewer = RowsViewer(Idx, T);

        /// A packed array of Records, followed by an array of T.
        ///
        /// The 0 address if the first T, to compute the allocated buffer offset
        /// the size of all records and add padding to align with the first T.
        bytes: [*]align(@alignOf(T)) const u8,
        allocated: Idx,
        row_count: Idx,
        records_offset: Idx,

        pub fn author(allocator: Allocator) Author {
            return Author{ .allocator = allocator };
        }

        pub fn deinit(self: Self, allocator: Allocator) void {
            const records = self.bytes - self.records_offset;
            const slice: []align(@alignOf(T)) const u8 = @alignCast(records[0..self.allocated]);
            allocator.free(slice);
        }

        fn rowRecord(self: Self, row: Idx) Record {
            assert(row < self.row_count);
            const records = self.bytes - self.records_offset;
            const slice = records[row * Record.byte_len ..][0..Record.byte_len];
            return mem.bytesToValue(Record, slice);
        }

        fn rowSlice(self: Self, row: Idx) []const T {
            const record = self.rowRecord(row);
            const byte_len = record.len * @sizeOf(T);
            const bytes = self.bytes[record.offset..][0..byte_len];
            return @alignCast(mem.bytesAsSlice(T, bytes));
        }

        // Viewer //////////////////////////////////////////////////////////////

        pub fn view(self: *const Self) Viewer {
            return .{
                .ctx = self,
                .vtable = &viewer_vtable,
            };
        }

        const viewer_vtable = Viewer.VTable{
            .allItems = allItems,
            .countItems = countItems,
            .hasItem = hasItem,
            .hasItems = hasItems,
            .findItem = findItem,
            .findItems = findItems,
            .itemAt = itemAt,
            .itemAtOrNull = itemAtOrNull,
            .itemsRange = itemsRange,
            .lastItem = lastItem,
            .lastItems = lastItems,
            .iterateItems = iterate,
        };

        fn cast(ctx: *const anyopaque) *const Self {
            return @ptrCast(@alignCast(ctx));
        }

        fn allItems(ctx: *const anyopaque, row: Idx) []const T {
            return cast(ctx).rowSlice(row);
        }

        fn countItems(ctx: *const anyopaque, row: Idx) Idx {
            return cast(ctx).rowRecord(row).len;
        }

        fn hasItem(ctx: *const anyopaque, row: Idx, item: T) bool {
            const slice = cast(ctx).rowSlice(row);
            return utils.indexOf(slice, item) != null;
        }

        fn hasItems(ctx: *const anyopaque, row: Idx, items: []const T) bool {
            const slice = cast(ctx).rowSlice(row);
            return utils.indexOfSlice(slice, items) != null;
        }

        fn findItem(ctx: *const anyopaque, row: Idx, item: T) Idx {
            const slice = cast(ctx).rowSlice(row);
            return utils.indexOf(slice, item) orelse unreachable;
        }

        fn findItems(ctx: *const anyopaque, row: Idx, items: []const T) Idx {
            const slice = cast(ctx).rowSlice(row);
            return utils.indexOfSlice(slice, items) orelse unreachable;
        }

        fn itemAt(ctx: *const anyopaque, row: Idx, i: Idx) T {
            return cast(ctx).rowSlice(row)[i];
        }

        fn itemAtOrNull(ctx: *const anyopaque, row: Idx, i: Idx) ?T {
            const items = cast(ctx).rowSlice(row);
            return if (i < items.len) items[i] else null;
        }

        fn itemsRange(ctx: *const anyopaque, row: Idx, i: Idx, n: Idx) []const T {
            const slice = cast(ctx).rowSlice(row);
            assert(i <= slice.len and n <= slice.len - i);
            return slice[i..][0..n];
        }

        fn lastItem(ctx: *const anyopaque, row: Idx) T {
            const slice = cast(ctx).rowSlice(row);
            assert(slice.len > 0);
            return slice[slice.len - 1];
        }

        fn lastItems(ctx: *const anyopaque, row: Idx, n: Idx) []const T {
            const slice = cast(ctx).rowSlice(row);
            assert(slice.len >= n);
            return slice[slice.len - n ..][0..n];
        }

        fn iterate(ctx: *const anyopaque, row: Idx) iter.Iterator(T, .{}) {
            const slice = cast(ctx).rowSlice(row);
            return .{ .items = slice };
        }

        pub const ReservedRow = struct {
            index: Idx,
            items_count: Idx,
            items_offset: Idx,
            items_buffer: *std.ArrayListUnmanaged(T),

            pub fn setItem(self: ReservedRow, i: usize, item: T) void {
                assert(i < self.items_count);
                self.items_buffer.items[self.items_offset + i] = item;
            }
        };

        pub const Author = struct {
            allocator: Allocator,
            records: std.ArrayListUnmanaged(u8) = .{},
            items: std.ArrayListUnmanaged(T) = .{},

            pub fn deinit(self: *Author) void {
                self.records.deinit(self.allocator);
                self.items.deinit(self.allocator);
            }

            pub fn count(self: Author) Idx {
                const len = self.records.items.len / Record.byte_len;
                return @intCast(len);
            }

            pub fn appendRow(self: *Author, items: []const T) !Idx {
                const index = self.count();
                assert(index < std.math.maxInt(Idx));
                assert(items.len <= std.math.maxInt(Idx));

                try self.records.appendSlice(self.allocator, mem.asBytes(&Record{
                    .len = @intCast(items.len),
                    .offset = @intCast(self.items.items.len * @sizeOf(T)),
                })[0..Record.byte_len]);
                errdefer self.records.shrinkRetainingCapacity(self.records.items.len - Record.byte_len);

                try self.items.appendSlice(self.allocator, items);
                return index;
            }

            pub fn reserveRow(self: *Author, n: Idx, value: T) !ReservedRow {
                const index = self.count();
                assert(n <= std.math.maxInt(Idx));
                assert(index < std.math.maxInt(Idx));

                const offset = self.items.items.len;
                try self.records.appendSlice(self.allocator, mem.asBytes(&Record{
                    .len = @intCast(n),
                    .offset = @intCast(offset * @sizeOf(T)),
                })[0..Record.byte_len]);
                errdefer self.records.shrinkRetainingCapacity(self.records.items.len - Record.byte_len);

                try self.items.appendNTimes(self.allocator, value, n);
                return .{
                    .index = index,
                    .items_count = n,
                    .items_offset = @intCast(offset),
                    .items_buffer = &self.items,
                };
            }

            /// The caller owns the returned memory.
            pub fn consume(self: *Author, allocator: Allocator) !Rows(T, options) {
                const row_count = self.count();
                const record_len = self.records.items.len;

                const offset = mem.alignForward(usize, record_len, @alignOf(T));
                const size = offset + self.items.items.len * @sizeOf(T);
                assert(size <= std.math.maxInt(Idx));

                const bytes = try allocator.allocWithOptions(u8, size, @alignOf(T), null);
                @memcpy(bytes[0..record_len], self.records.items);
                @memcpy(bytes[offset..size], mem.sliceAsBytes(self.items.items));

                self.records.deinit(self.allocator);
                self.items.deinit(self.allocator);

                return Rows(T, options){
                    .row_count = row_count,
                    .records_offset = @intCast(offset),
                    .allocated = @intCast(size),
                    .bytes = @alignCast(bytes[offset..].ptr),
                };
            }
        };
    };
}

test "Rows" {
    const rows = blk: {
        var author = Rows(u8, .{}).author(test_alloc);
        errdefer author.deinit();

        try testing.expectEqual(0, try author.appendRow(&.{ 1, 2, 3 }));

        const reserved = try author.reserveRow(2, 0);
        try testing.expectEqual(1, reserved.index);
        reserved.setItem(0, 4);
        reserved.setItem(1, 5);

        break :blk try author.consume(test_alloc);
    };
    defer rows.deinit(test_alloc);

    try testing.expectEqual(3, rows.view().countItems(0));
    try testing.expectEqual(false, rows.view().hasItem(0, 8));
    try testing.expectEqual(true, rows.view().hasItem(1, 5));
    try testing.expectEqual(false, rows.view().hasItems(0, &.{ 1, 3 }));
    try testing.expectEqual(true, rows.view().hasItems(0, &.{ 2, 3 }));
    try testing.expectEqual(1, rows.view().findItem(0, 2));
    try testing.expectEqual(1, rows.view().findItems(0, &.{ 2, 3 }));
    try testing.expectEqualSlices(u8, &[_]u8{ 4, 5 }, rows.view().allItems(1));
    try testing.expectEqual(3, rows.view().itemAt(0, 2));
    try testing.expectEqualSlices(u8, &[_]u8{ 2, 3 }, rows.view().itemsRange(0, 1, 2));
    try testing.expectEqual(3, rows.view().lastItem(0));
    try testing.expectEqualSlices(u8, &[_]u8{ 2, 3 }, rows.view().lastItems(0, 2));
    try testing.expectEqualSlices(u8, &[_]u8{ 4, 5 }, rows.view().iterateItems(1).items);
    try testing.expectEqual(5, rows.view().itemAt(1, 1));
    try testing.expectEqual(5, rows.view().itemAtOrNull(1, 1));
    try testing.expectEqualDeep(null, rows.view().itemAtOrNull(1, 2));
}

pub fn MutableRows(comptime T: type, comptime options: RowsOptions(T)) type {
    const utils = RowsUtils(T, options);
    const Idx = options.Indexer;
    const Row = std.ArrayListUnmanaged(T);

    return struct {
        const Self = @This();
        pub const Viewer = RowsViewer(Idx, T);

        rows: std.ArrayListUnmanaged(Row) = .{},
        gaps: AutoSlots(Idx) = .{},

        pub fn deinit(self: *Self, allocator: Allocator) void {
            for (self.rows.items) |*row| row.deinit(allocator);
            self.rows.deinit(allocator);
            self.gaps.deinit(allocator);
        }

        pub fn claimRow(self: *Self, allocator: Allocator) !Idx {
            if (self.gaps.takeLast()) |gap| {
                return @intCast(gap);
            } else {
                assert(self.rows.items.len < std.math.maxInt(Idx));

                const i = self.rows.items.len;
                try self.rows.append(allocator, Row{});
                return @intCast(i);
            }
        }

        pub fn claimRowWithSlice(self: *Self, allocator: Allocator, items: []const T) !Idx {
            if (self.gaps.takeLast()) |gap| {
                errdefer self.gaps.put(allocator, gap) catch {};
                try self.rows.items[gap].appendSlice(allocator, items);
                return @intCast(gap);
            } else {
                assert(self.rows.items.len < std.math.maxInt(Idx));

                var row = Row{};
                try row.appendSlice(allocator, items);
                errdefer row.deinit(allocator);

                const i = self.rows.items.len;
                try self.rows.append(allocator, row);
                return @intCast(i);
            }
        }

        pub fn releaseRow(self: *Self, allocator: Allocator, row: Idx) void {
            if (self.rows.items.len == row + 1) {
                var list = self.rows.pop();
                list.deinit(allocator);
            } else {
                self.rows.items[row].clearAndFree(allocator);
                self.gaps.put(allocator, row) catch {};
            }
        }

        // Mutate Row //////////////////////////////////////////////////////////

        pub fn append(self: *Self, allocator: Allocator, row: Idx, item: T) !void {
            const list = &self.rows.items[row];
            assert(list.items.len < std.math.maxInt(Idx));
            try list.append(allocator, item);
        }

        pub fn appendSlice(self: *Self, allocator: Allocator, row: Idx, items: []const T) !void {
            const list = &self.rows.items[row];
            assert(list.items.len < std.math.maxInt(Idx) - items.len);
            try list.appendSlice(allocator, items);
        }

        pub fn insert(self: *Self, allocator: Allocator, layout: Reorder, row: Idx, i: Idx, item: T) !void {
            const list = &self.rows.items[row];
            assert(i <= list.items.len);
            assert(list.items.len < std.math.maxInt(Idx));
            switch (layout) {
                .ordered => try list.insert(allocator, i, item),
                .swap => {
                    if (i == list.items.len) {
                        try list.append(allocator, item);
                    } else {
                        try list.append(allocator, list.items[i]);
                        list.items[i] = item;
                    }
                },
            }
        }

        pub fn insertSlice(self: *Self, allocator: Allocator, layout: Reorder, row: Idx, i: Idx, items: []const T) !void {
            const list = &self.rows.items[row];
            const row_len = list.items.len;
            assert(i <= row_len);
            assert(row_len < std.math.maxInt(Idx) - items.len);
            switch (layout) {
                .ordered => try list.insertSlice(allocator, i, items),
                .swap => {
                    if (i == row_len) {
                        try list.appendSlice(allocator, items);
                    } else {
                        const move_len = row_len - i;
                        if (move_len < items.len) {
                            const end = try list.addManyAsSlice(allocator, items.len);
                            @memcpy(end[end.len - move_len ..], list.items[i..][0..move_len]);
                            @memcpy(list.items[i..], items);
                        } else {
                            const end = try list.addManyAsSlice(allocator, items.len);
                            @memcpy(end, list.items[i..][0..items.len]);
                            @memcpy(list.items[i..][0..items.len], items);
                        }
                    }
                },
            }
        }

        pub fn pop(self: *Self, row: Idx) T {
            var list = &self.rows.items[row];
            return list.pop();
        }

        pub fn popSlice(self: *Self, row: Idx, n: Idx) []const T {
            var list = &self.rows.items[row];
            const i = list.items.len - n;
            defer list.shrinkRetainingCapacity(i);
            return list.items[i..][0..n];
        }

        pub fn drop(self: *Self, layout: Reorder, row: Idx, item: T) void {
            var list = &self.rows.items[row];
            const i = utils.indexOf(list.items, item) orelse unreachable;
            switch (layout) {
                .swap => _ = list.swapRemove(i),
                .ordered => _ = list.orderedRemove(i),
            }
        }

        pub fn dropAt(self: *Self, layout: Reorder, row: Idx, i: Idx) T {
            var list = &self.rows.items[row];
            return switch (layout) {
                .swap => list.swapRemove(i),
                .ordered => list.orderedRemove(i),
            };
        }

        pub fn dropSlice(self: *Self, layout: Reorder, row: Idx, i: Idx, n: Idx) []const T {
            var list = &self.rows.items[row];
            const list_len = list.items.len;
            assert(i <= list_len and n <= list_len - i);

            var buffer: [64]T = undefined;
            assert(n <= buffer.len);
            @memcpy(buffer[0..n], list.items[i..][0..n]);

            switch (layout) {
                .swap => {
                    const move_len = @min(n, list_len - i - n);
                    @memcpy(list.items[i..][0..move_len], list.items[list_len - move_len ..][0..move_len]);
                },
                .ordered => {
                    const src = i + n;
                    const move_len = list_len - src;
                    mem.copyForwards(T, list.items[i..][0..move_len], list.items[src..][0..move_len]);
                },
            }

            const new_len = list_len - n;
            @memcpy(list.items[new_len..], buffer[0..n]);
            defer list.shrinkRetainingCapacity(new_len);
            return list.items[new_len..][0..n];
        }

        pub fn move(self: *Self, layout: Reorder, row: Idx, item: T, to: Idx) void {
            const slice = self.rows.items[row].items;
            const i = utils.indexOf(slice, item) orelse unreachable;
            if (i == to) return;
            switch (layout) {
                .swap => mem.swap(T, &slice[i], &slice[to]),
                .ordered => {
                    if (i < to) {
                        const len = to - i;
                        mem.copyForwards(T, slice[i..][0..len], slice[i + 1 ..][0..len]);
                    } else {
                        const len = i - to;
                        mem.copyBackwards(T, slice[to + 1 ..][0..len], slice[to..][0..len]);
                    }
                    slice[to] = item;
                },
            }
        }

        pub fn moveAt(self: *Self, layout: Reorder, row: Idx, i: Idx, to: Idx) void {
            if (i == to) return;
            const slice = self.rows.items[row].items;
            switch (layout) {
                .swap => mem.swap(T, &slice[i], &slice[to]),
                .ordered => {
                    const item = slice[i];
                    if (i < to) {
                        const len = to - i;
                        mem.copyForwards(T, slice[i..][0..len], slice[i + 1 ..][0..len]);
                    } else {
                        const len = i - to;
                        mem.copyBackwards(T, slice[to + 1 ..][0..len], slice[to..][0..len]);
                    }
                    slice[to] = item;
                },
            }
        }

        pub fn moveSlice(self: *Self, layout: Reorder, row: Idx, i: Idx, n: Idx, to: Idx) void {
            const items = self.rows.items[row].items;
            assert(i <= items.len and n <= items.len - i);

            var buffer: [64]T = undefined;
            assert(n <= buffer.len);
            @memcpy(buffer[0..n], items[i..][0..n]);

            switch (layout) {
                .swap => {
                    if (@max(i, to) - n >= @min(i, to)) {
                        @memcpy(items[i..][0..n], items[to..][0..n]);
                    } else if (i < to) {
                        mem.copyForwards(T, items[i..][0..n], items[to..][0..n]);
                    } else {
                        mem.copyBackwards(T, items[i..][0..n], items[to..][0..n]);
                    }
                },
                .ordered => {
                    if (i < to) {
                        const move_len = to - i;
                        mem.copyForwards(T, items[i..][0..move_len], items[i + n ..][0..move_len]);
                    } else {
                        const move_len = i - to;
                        mem.copyBackwards(T, items[to + n ..][0..move_len], items[to..][0..move_len]);
                    }
                },
            }

            @memcpy(items[to..][0..n], buffer[0..n]);
        }

        pub fn refAt(self: *Self, row: Idx, i: Idx) *T {
            const slice = self.rows.items[row].items;
            return &slice[i];
        }

        pub fn refSlice(self: *Self, row: Idx, i: Idx, n: Idx) []T {
            const slice = self.rows.items[row].items;
            assert(i <= slice.len and n <= slice.len - i);
            return slice[i..][0..n];
        }

        pub fn refLast(self: *Self, row: Idx) *T {
            const slice = self.rows.items[row].items;
            return &slice[slice.len - 1];
        }

        pub fn refLastSlice(self: *Self, row: Idx, n: Idx) []T {
            const slice = self.rows.items[row].items;
            assert(slice.len >= n);
            return slice[slice.len - n ..][0..n];
        }

        pub fn iterateMutable(self: *Self, row: Idx) iter.Iterator(T, .{ .mutable = true }) {
            return .{ .items = self.rows.items[row].items };
        }

        // Viewer //////////////////////////////////////////////////////////////

        pub fn view(self: *const Self) Viewer {
            return .{
                .ctx = self,
                .vtable = &viewer_vtable,
            };
        }

        const viewer_vtable = Viewer.VTable{
            .allItems = allItems,
            .countItems = countItems,
            .hasItem = hasItem,
            .hasItems = hasItems,
            .findItem = findItem,
            .findItems = findItems,
            .itemAt = itemAt,
            .itemAtOrNull = itemAtOrNull,
            .itemsRange = itemsRange,
            .lastItem = lastItem,
            .lastItems = lastItems,
            .iterateItems = iterate,
        };

        fn cast(ctx: *const anyopaque) *const Self {
            return @ptrCast(@alignCast(ctx));
        }

        fn allItems(ctx: *const anyopaque, row: Idx) []const T {
            return cast(ctx).rows.items[row].items;
        }

        fn countItems(ctx: *const anyopaque, row: Idx) Idx {
            return @intCast(cast(ctx).rows.items[row].items.len);
        }

        fn hasItem(ctx: *const anyopaque, row: Idx, item: T) bool {
            const slice = cast(ctx).rows.items[row].items;
            return utils.indexOf(slice, item) != null;
        }

        fn hasItems(ctx: *const anyopaque, row: Idx, items: []const T) bool {
            const slice = cast(ctx).rows.items[row].items;
            return utils.indexOfSlice(slice, items) != null;
        }

        fn findItem(ctx: *const anyopaque, row: Idx, item: T) Idx {
            const slice = cast(ctx).rows.items[row].items;
            return utils.indexOf(slice, item) orelse unreachable;
        }

        fn findItems(ctx: *const anyopaque, row: Idx, items: []const T) Idx {
            const slice = cast(ctx).rows.items[row].items;
            return utils.indexOfSlice(slice, items) orelse unreachable;
        }

        fn itemAt(ctx: *const anyopaque, row: Idx, i: Idx) T {
            return cast(ctx).rows.items[row].items[i];
        }

        fn itemAtOrNull(ctx: *const anyopaque, row: Idx, i: Idx) ?T {
            const items = cast(ctx).rows.items[row].items;
            return if (i < items.len) items[i] else null;
        }

        fn itemsRange(ctx: *const anyopaque, row: Idx, i: Idx, n: Idx) []const T {
            const slice = cast(ctx).rows.items[row].items;
            assert(i <= slice.len and n <= slice.len - i);
            return slice[i..][0..n];
        }

        fn lastItem(ctx: *const anyopaque, row: Idx) T {
            const slice = cast(ctx).rows.items[row].items;
            assert(slice.len > 0);
            return slice[slice.len - 1];
        }

        fn lastItems(ctx: *const anyopaque, row: Idx, n: Idx) []const T {
            const slice = cast(ctx).rows.items[row].items;
            assert(slice.len >= n);
            return slice[slice.len - n ..][0..n];
        }

        fn iterate(ctx: *const anyopaque, row: Idx) iter.Iterator(T, .{}) {
            const slice = cast(ctx).rows.items[row].items;
            return .{ .items = slice };
        }
    };
}

test "MutableRows: view" {
    var t0: [3]u8 = .{ 1, 2, 3 };
    var t1: [2]u8 = .{ 4, 5 };
    var items: [2]std.ArrayListUnmanaged(u8) = .{
        std.ArrayListUnmanaged(u8).initBuffer(&t0),
        std.ArrayListUnmanaged(u8).initBuffer(&t1),
    };
    items[0].items.len = 3;
    items[1].items.len = 2;
    var rows = MutableRows(u8, .{}){};
    rows.rows.items = &items;

    const view = rows.view();
    try testing.expectEqual(3, view.countItems(0));
    try testing.expectEqual(false, view.hasItem(0, 8));
    try testing.expectEqual(true, view.hasItem(1, 5));
    try testing.expectEqual(false, view.hasItems(0, &.{ 1, 3 }));
    try testing.expectEqual(true, view.hasItems(0, &.{ 2, 3 }));
    try testing.expectEqual(1, view.findItem(0, 2));
    try testing.expectEqual(1, view.findItems(0, &.{ 2, 3 }));
    try testing.expectEqualSlices(u8, &[_]u8{ 4, 5 }, view.allItems(1));
    try testing.expectEqual(3, view.itemAt(0, 2));
    try testing.expectEqualSlices(u8, &[_]u8{ 2, 3 }, view.itemsRange(0, 1, 2));
    try testing.expectEqual(3, view.lastItem(0));
    try testing.expectEqualSlices(u8, &[_]u8{ 2, 3 }, view.lastItems(0, 2));
    try testing.expectEqualSlices(u8, &[_]u8{ 4, 5 }, view.iterateItems(1).items);
    try testing.expectEqual(5, view.itemAt(1, 1));
    try testing.expectEqual(5, view.itemAtOrNull(1, 1));
    try testing.expectEqualDeep(null, view.itemAtOrNull(1, 2));
}

test "MutableRows: mutate" {
    var rows = MutableRows(u8, .{}){};
    defer rows.deinit(test_alloc);

    const r0 = try rows.claimRow(test_alloc);
    try testing.expectEqual(0, rows.view().countItems(r0));

    try rows.append(test_alloc, r0, 1);
    try rows.appendSlice(test_alloc, r0, &.{ 2, 3 });
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3 }, rows.view().allItems(r0));

    try rows.insert(test_alloc, .ordered, r0, 1, 4);
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 4, 2, 3 }, rows.view().allItems(r0));

    try rows.insert(test_alloc, .swap, r0, 1, 5);
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 5, 2, 3, 4 }, rows.view().allItems(r0));

    try rows.insertSlice(test_alloc, .ordered, r0, 1, &.{ 6, 7 });
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 6, 7, 5, 2, 3, 4 }, rows.view().allItems(r0));

    try rows.insertSlice(test_alloc, .swap, r0, 1, &.{ 8, 9 });
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 8, 9, 5, 2, 3, 4, 6, 7 }, rows.view().allItems(r0));

    try testing.expectEqual(7, rows.pop(r0));
    try testing.expectEqualSlices(u8, &[_]u8{ 4, 6 }, rows.popSlice(r0, 2));
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 8, 9, 5, 2, 3 }, rows.view().allItems(r0));

    rows.drop(.ordered, r0, 9);
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 8, 5, 2, 3 }, rows.view().allItems(r0));

    rows.drop(.swap, r0, 8);
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 3, 5, 2 }, rows.view().allItems(r0));

    try testing.expectEqual(3, rows.dropAt(.swap, r0, 1));
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 5 }, rows.view().allItems(r0));

    try testing.expectEqual(2, rows.dropAt(.ordered, r0, 1));
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 5 }, rows.view().allItems(r0));

    try rows.appendSlice(test_alloc, r0, &.{ 6, 7 });
    try rows.insertSlice(test_alloc, .ordered, r0, 1, &.{ 2, 3, 4 });

    try testing.expectEqualSlices(u8, &[_]u8{ 2, 3 }, rows.dropSlice(.ordered, r0, 1, 2));
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 4, 5, 6, 7 }, rows.view().allItems(r0));

    try testing.expectEqualSlices(u8, &[_]u8{ 1, 4 }, rows.dropSlice(.swap, r0, 0, 2));
    try testing.expectEqualSlices(u8, &[_]u8{ 6, 7, 5 }, rows.view().allItems(r0));

    rows.refAt(r0, 0).* += 2;
    rows.refSlice(r0, 1, 2)[1] += 1;
    try testing.expectEqualSlices(u8, &[_]u8{ 8, 7, 6 }, rows.view().allItems(r0));

    rows.refLast(r0).* -= 4;
    try testing.expectEqual(2, rows.view().lastItem(r0));

    rows.refLastSlice(r0, 2)[0] -= 2;
    try testing.expectEqualSlices(u8, &[_]u8{ 8, 5, 2 }, rows.view().allItems(r0));

    const r1 = try rows.claimRowWithSlice(test_alloc, &.{ 1, 2, 3, 4, 5 });
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4, 5 }, rows.view().allItems(r1));

    rows.move(.swap, r1, 2, 3);
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 4, 3, 2, 5 }, rows.view().allItems(r1));

    rows.move(.ordered, r1, 4, 4);
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 3, 2, 5, 4 }, rows.view().allItems(r1));

    rows.moveAt(.swap, r1, 0, 4);
    try testing.expectEqualSlices(u8, &[_]u8{ 4, 3, 2, 5, 1 }, rows.view().allItems(r1));

    rows.moveAt(.ordered, r1, 1, 3);
    try testing.expectEqualSlices(u8, &[_]u8{ 4, 2, 5, 3, 1 }, rows.view().allItems(r1));

    rows.moveSlice(.swap, r1, 0, 2, 2);
    try testing.expectEqualSlices(u8, &[_]u8{ 5, 3, 4, 2, 1 }, rows.view().allItems(r1));

    rows.moveSlice(.swap, r1, 2, 2, 0);
    try testing.expectEqualSlices(u8, &[_]u8{ 4, 2, 5, 3, 1 }, rows.view().allItems(r1));

    rows.moveSlice(.ordered, r1, 0, 2, 3);
    try testing.expectEqualSlices(u8, &[_]u8{ 5, 3, 1, 4, 2 }, rows.view().allItems(r1));

    rows.moveSlice(.ordered, r1, 2, 2, 1);
    try testing.expectEqualSlices(u8, &[_]u8{ 5, 1, 4, 3, 2 }, rows.view().allItems(r1));

    rows.releaseRow(test_alloc, r1);
    try testing.expectEqual(r1, try rows.claimRow(test_alloc));
    try testing.expectEqual(0, rows.view().countItems(r1));

    try rows.appendSlice(test_alloc, r1, &.{ 2, 3 });
    var it = rows.iterateMutable(r1);
    while (it.next()) |item| item.* *= 2;
    try testing.expectEqualSlices(u8, &[_]u8{ 4, 6 }, rows.view().allItems(r1));
}

fn RowsUtils(comptime T: type, comptime options: RowsOptions(T)) type {
    const Idx = options.Indexer;
    const eqlFn = comptime options.equalFn orelse std.meta.eql;
    const equatable = switch (@typeInfo(T)) {
        .@"struct", .error_union, .@"union", .array, .vector, .pointer, .optional => false,
        else => true,
    };

    return struct {
        pub fn indexOf(haystack: []const T, needle: T) ?Idx {
            if (comptime equatable and options.equalFn == null) {
                return if (mem.indexOfScalar(T, haystack, needle)) |i| @intCast(i) else null;
            } else {
                for (haystack.items, 0..) |t, i| {
                    if (eqlFn(t, needle)) return @intCast(i);
                }
                return null;
            }
        }

        pub fn indexOfSlice(haystack: []const T, needle: []const T) ?Idx {
            if (comptime equatable and options.equalFn == null) {
                return if (mem.indexOf(T, haystack, needle)) |i| @intCast(i) else null;
            } else {
                assert(needle.len <= haystack.items.len);
                main: for (0..haystack.items.len - needle.len + 1) |i| {
                    for (0..needle.len) |n| {
                        if (!eqlFn(haystack.items[i + n], needle[n])) continue :main;
                    }
                    return @intCast(i);
                }
                return null;
            }
        }
    };
}

pub fn RowsViewer(comptime Indexer: type, comptime T: type) type {
    return struct {
        const Self = @This();

        ctx: *const anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            allItems: *const fn (ctx: *const anyopaque, row: Indexer) []const T,
            countItems: *const fn (ctx: *const anyopaque, row: Indexer) Indexer,
            hasItem: *const fn (ctx: *const anyopaque, row: Indexer, item: T) bool,
            hasItems: *const fn (ctx: *const anyopaque, row: Indexer, items: []const T) bool,
            findItem: *const fn (ctx: *const anyopaque, row: Indexer, item: T) Indexer,
            findItems: *const fn (ctx: *const anyopaque, row: Indexer, items: []const T) Indexer,
            itemAt: *const fn (ctx: *const anyopaque, row: Indexer, i: Indexer) T,
            itemAtOrNull: *const fn (ctx: *const anyopaque, row: Indexer, i: Indexer) ?T,
            itemsRange: *const fn (ctx: *const anyopaque, row: Indexer, i: Indexer, n: Indexer) []const T,
            lastItem: *const fn (ctx: *const anyopaque, row: Indexer) T,
            lastItems: *const fn (ctx: *const anyopaque, row: Indexer, n: Indexer) []const T,
            iterateItems: *const fn (ctx: *const anyopaque, row: Indexer) iter.Iterator(T, .{}),
        };

        pub inline fn allItems(self: Self, row: Indexer) []const T {
            return self.vtable.allItems(self.ctx, row);
        }

        pub inline fn countItems(self: Self, row: Indexer) Indexer {
            return self.vtable.countItems(self.ctx, row);
        }

        pub inline fn hasItem(self: Self, row: Indexer, item: T) bool {
            return self.vtable.hasItem(self.ctx, row, item);
        }

        pub inline fn hasItems(self: Self, row: Indexer, items: []const T) bool {
            return self.vtable.hasItems(self.ctx, row, items);
        }

        pub inline fn findItem(self: Self, row: Indexer, item: T) Indexer {
            return self.vtable.findItem(self.ctx, row, item);
        }

        pub inline fn findItems(self: Self, row: Indexer, items: []const T) Indexer {
            return self.vtable.findItems(self.ctx, row, items);
        }

        pub inline fn itemAt(self: Self, row: Indexer, i: Indexer) T {
            return self.vtable.itemAt(self.ctx, row, i);
        }

        pub inline fn itemAtOrNull(self: Self, row: Indexer, i: Indexer) ?T {
            return self.vtable.itemAtOrNull(self.ctx, row, i);
        }

        pub inline fn itemsRange(self: Self, row: Indexer, i: Indexer, n: Indexer) []const T {
            return self.vtable.itemsRange(self.ctx, row, i, n);
        }

        pub inline fn lastItem(self: Self, row: Indexer) T {
            return self.vtable.lastItem(self.ctx, row);
        }

        pub inline fn lastItems(self: Self, row: Indexer, n: Indexer) []const T {
            return self.vtable.lastItems(self.ctx, row, n);
        }

        pub inline fn iterateItems(self: Self, row: Indexer) iter.Iterator(T, .{}) {
            return self.vtable.iterateItems(self.ctx, row);
        }
    };
}
