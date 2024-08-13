const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;
const test_alloc = testing.allocator;
const iter = @import("iterator.zig");
const Reorder = @import("shared.zig").Reorder;
const DynamicSlots = @import("slots.zig").DynamicSlots;
const DefaultIndexer = @import("shared.zig").DefaultIndexer;

pub fn SparseRowsOptions(comptime T: type) type {
    return struct {
        Indexer: type = DefaultIndexer,
        equalFn: ?fn (a: T, b: T) bool = null,
    };
}

fn RowRecord(comptime I: type) type {
    return packed struct {
        offset: u32,
        len: I,

        pub const byte_len = @divExact(@bitSizeOf(@This()), 8);
    };
}

pub fn SparseRows(comptime T: type, comptime options: SparseRowsOptions(T)) type {
    const I = options.Indexer;
    const Record = RowRecord(I);
    const utils = RowsUtils(T, options);

    return struct {
        const Self = @This();
        pub const Query = SparseRowsQuery(I, T);
        pub const Author = SparseRowsAuthor(T, options);

        /// A packed array of Records, followed by an array of T.
        ///
        /// The 0 address if the first T, to compute the allocated buffer offset
        /// the size of all records and add padding to align with the first T.
        bytes: [*]align(@alignOf(T)) const u8,
        allocated: I,
        row_count: I,

        pub fn deinit(self: Self, allocator: Allocator) void {
            const offset = mem.alignForward(usize, Record.byte_len * self.row_count, @alignOf(T));
            const slice = (self.bytes - offset)[0..self.allocated];
            allocator.free(slice);
        }

        fn rowRecord(self: Self, row: I) Record {
            assert(row < self.row_count);
            const byte_len = Record.byte_len * self.row_count;
            const records = self.bytes - mem.alignForward(usize, byte_len, @alignOf(T));
            const slice = records[row * Record.byte_len ..][0..Record.byte_len];
            return mem.bytesToValue(Record, slice);
        }

        fn rowSlice(self: Self, row: I) []const T {
            const record = self.rowRecord(row);
            const byte_len = record.len * @sizeOf(T);
            const bytes = self.bytes[record.offset..][0..byte_len];
            return mem.bytesAsSlice(T, bytes);
        }

        // Query Row ///////////////////////////////////////////////////////////

        pub fn query(self: *const Self) Query {
            return .{
                .ctx = self,
                .vtable = &query_vtable,
            };
        }

        const query_vtable = Query.VTable{
            .count = count,
            .contains = contains,
            .containsSlice = containsSlice,
            .orderOf = orderOf,
            .orderOfSlice = orderOfSlice,
            .view = view,
            .peekAt = peekAt,
            .peekSlice = peekSlice,
            .peekLast = peekLast,
            .peekLastSlice = peekLastSlice,
            .iterate = iterate,
            .iterateReverse = iterateReverse,
        };

        fn cast(ctx: *const anyopaque) *const Self {
            return @ptrCast(@alignCast(ctx));
        }

        fn count(ctx: *const anyopaque, row: I) I {
            return cast(ctx).rowRecord(row).len;
        }

        fn contains(ctx: *const anyopaque, row: I, item: T) bool {
            const slice = cast(ctx).rowSlice(row);
            return utils.indexOf(slice, item) != null;
        }

        fn containsSlice(ctx: *const anyopaque, row: I, items: []const T) bool {
            const slice = cast(ctx).rowSlice(row);
            return utils.indexOfSlice(slice, items) != null;
        }

        fn orderOf(ctx: *const anyopaque, row: I, item: T) I {
            const slice = cast(ctx).rowSlice(row);
            return utils.indexOf(slice, item) orelse unreachable;
        }

        fn orderOfSlice(ctx: *const anyopaque, row: I, items: []const T) I {
            const slice = cast(ctx).rowSlice(row);
            return utils.indexOfSlice(slice, items) orelse unreachable;
        }

        fn view(ctx: *const anyopaque, row: I) []const T {
            return cast(ctx).rowSlice(row);
        }

        fn peekAt(ctx: *const anyopaque, row: I, i: I) T {
            return cast(ctx).rowSlice(row)[i];
        }

        fn peekSlice(ctx: *const anyopaque, row: I, i: I, n: I) []const T {
            const slice = cast(ctx).rowSlice(row);
            assert(i <= slice.len and n <= slice.len - i);
            return slice[i..][0..n];
        }

        fn peekLast(ctx: *const anyopaque, row: I) T {
            const slice = cast(ctx).rowSlice(row);
            assert(slice.len > 0);
            return slice[slice.len - 1];
        }

        fn peekLastSlice(ctx: *const anyopaque, row: I, n: I) []const T {
            const slice = cast(ctx).rowSlice(row);
            assert(slice.len >= n);
            return slice[slice.len - n ..][0..n];
        }

        fn iterate(ctx: *const anyopaque, row: I) iter.Iterator(T, .{}) {
            const slice = cast(ctx).rowSlice(row);
            return .{ .items = slice };
        }

        fn iterateReverse(ctx: *const anyopaque, row: I) iter.Iterator(T, .{ .reverse = true }) {
            const slice = cast(ctx).rowSlice(row);
            return .{ .items = slice };
        }
    };
}

pub fn SparseRowsAuthor(comptime T: type, comptime options: SparseRowsOptions(T)) type {
    const I = options.Indexer;
    const Record = RowRecord(I);

    return struct {
        const Self = @This();

        allocator: Allocator,
        records: std.ArrayListUnmanaged(u8) = .{},
        items: std.ArrayListUnmanaged(T) = .{},

        pub fn deinit(self: *Self) void {
            self.records.deinit(self.allocator);
            self.items.deinit(self.allocator);
        }

        pub fn count(self: Self) I {
            const len = self.records.items.len / Record.byte_len;
            return @intCast(len);
        }

        pub fn appendRow(self: *Self, items: []const T) !I {
            const index = self.count();
            assert(index < std.math.maxInt(I));
            assert(items.len <= std.math.maxInt(I));

            try self.records.appendSlice(self.allocator, mem.asBytes(&Record{
                .len = @intCast(items.len),
                .offset = @intCast(self.items.items.len * @sizeOf(T)),
            })[0..Record.byte_len]);
            errdefer self.records.shrinkRetainingCapacity(self.records.items.len - Record.byte_len);

            try self.items.appendSlice(self.allocator, items);

            return index;
        }

        pub fn consume(self: *Self, allocator: Allocator) !SparseRows(T, options) {
            const row_count = self.count();
            const record_len = self.records.items.len;

            const offset = mem.alignForward(usize, record_len, @alignOf(T));
            const size = offset + self.items.items.len * @sizeOf(T);
            assert(size <= std.math.maxInt(I));

            const bytes = try allocator.allocWithOptions(u8, size, @alignOf(T), null);
            @memcpy(bytes[0..record_len], self.records.items);
            @memcpy(bytes[offset..size], mem.sliceAsBytes(self.items.items));

            self.records.deinit(self.allocator);
            self.items.deinit(self.allocator);

            return SparseRows(T, options){
                .bytes = bytes[offset..].ptr,
                .allocated = @intCast(size),
                .row_count = row_count,
            };
        }
    };
}

test "SparseRows" {
    const rows = blk: {
        var author = SparseRowsAuthor(u8, .{}){
            .allocator = test_alloc,
        };
        errdefer author.deinit();

        try testing.expectEqual(0, try author.appendRow(&.{ 1, 2, 3 }));
        try testing.expectEqual(1, try author.appendRow(&.{ 4, 5 }));

        break :blk try author.consume(test_alloc);
    };
    defer rows.deinit(test_alloc);

    try testing.expectEqual(3, rows.query().count(0));
    try testing.expectEqual(false, rows.query().contains(0, 8));
    try testing.expectEqual(true, rows.query().contains(1, 5));
    try testing.expectEqual(false, rows.query().containsSlice(0, &.{ 1, 3 }));
    try testing.expectEqual(true, rows.query().containsSlice(0, &.{ 2, 3 }));
    try testing.expectEqual(1, rows.query().orderOf(0, 2));
    try testing.expectEqual(1, rows.query().orderOfSlice(0, &.{ 2, 3 }));
    try testing.expectEqualSlices(u8, &[_]u8{ 4, 5 }, rows.query().view(1));
    try testing.expectEqual(3, rows.query().peekAt(0, 2));
    try testing.expectEqualSlices(u8, &[_]u8{ 2, 3 }, rows.query().peekSlice(0, 1, 2));
    try testing.expectEqual(3, rows.query().peekLast(0));
    try testing.expectEqualSlices(u8, &[_]u8{ 2, 3 }, rows.query().peekLastSlice(0, 2));
    try testing.expectEqualSlices(u8, &[_]u8{ 4, 5 }, rows.query().iterate(1).items);

    var it = rows.query().iterateReverse(1);
    for (&[_]u8{ 5, 4 }) |expected| try testing.expectEqual(expected, it.next());
    try testing.expectEqual(null, it.next());
}

pub fn MutableSparseRows(comptime T: type, comptime options: SparseRowsOptions(T)) type {
    const utils = RowsUtils(T, options);
    const I = options.Indexer;
    const Row = std.ArrayListUnmanaged(T);

    return struct {
        const Self = @This();
        pub const Query = SparseRowsQuery(I, T);

        rows: std.ArrayListUnmanaged(Row) = .{},
        gaps: DynamicSlots(I) = .{},

        pub fn deinit(self: *Self, allocator: Allocator) void {
            for (self.rows.items) |*row| row.deinit(allocator);
            self.rows.deinit(allocator);
            self.gaps.deinit(allocator);
        }

        pub fn claimRow(self: *Self, allocator: Allocator) !I {
            if (self.gaps.takeLast()) |gap| {
                return @intCast(gap);
            } else {
                assert(self.rows.items.len < std.math.maxInt(I));

                const i = self.rows.items.len;
                try self.rows.append(allocator, Row{});
                return @intCast(i);
            }
        }

        pub fn claimRowWithSlice(self: *Self, allocator: Allocator, items: []const T) !I {
            if (self.gaps.takeLast()) |gap| {
                return @intCast(gap);
            } else {
                assert(self.rows.items.len < std.math.maxInt(I));

                var row = Row{};
                try row.appendSlice(allocator, items);
                errdefer row.deinit(allocator);

                const i = self.rows.items.len;
                try self.rows.append(allocator, row);
                return @intCast(i);
            }
        }

        pub fn releaseRow(self: *Self, allocator: Allocator, row: I) void {
            if (self.rows.items.len == row + 1) {
                var list = self.rows.pop();
                list.deinit(allocator);
            } else {
                self.rows.items[row].clearAndFree(allocator);
                self.gaps.put(allocator, row) catch {};
            }
        }

        // Mutate Row //////////////////////////////////////////////////////////

        pub fn append(self: *Self, allocator: Allocator, row: I, item: T) !void {
            const list = &self.rows.items[row];
            assert(list.items.len < std.math.maxInt(I));
            try list.append(allocator, item);
        }

        pub fn appendSlice(self: *Self, allocator: Allocator, row: I, items: []const T) !void {
            const list = &self.rows.items[row];
            assert(list.items.len < std.math.maxInt(I) - items.len);
            try list.appendSlice(allocator, items);
        }

        pub fn insert(self: *Self, allocator: Allocator, layout: Reorder, row: I, i: I, item: T) !void {
            const list = &self.rows.items[row];
            assert(i <= list.items.len);
            assert(list.items.len < std.math.maxInt(I));
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

        pub fn insertSlice(self: *Self, allocator: Allocator, layout: Reorder, row: I, i: I, items: []const T) !void {
            const list = &self.rows.items[row];
            const row_len = list.items.len;
            assert(i <= row_len);
            assert(row_len < std.math.maxInt(I) - items.len);
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

        pub fn pop(self: *Self, row: I) T {
            var list = &self.rows.items[row];
            return list.pop();
        }

        pub fn popSlice(self: *Self, row: I, n: I) []const T {
            var list = &self.rows.items[row];
            const i = list.items.len - n;
            defer list.shrinkRetainingCapacity(i);
            return list.items[i..][0..n];
        }

        pub fn drop(self: *Self, layout: Reorder, row: I, item: T) void {
            var list = &self.rows.items[row];
            const i = utils.indexOf(list.items, item) orelse unreachable;
            switch (layout) {
                .swap => _ = list.swapRemove(i),
                .ordered => _ = list.orderedRemove(i),
            }
        }

        pub fn dropAt(self: *Self, layout: Reorder, row: I, i: I) T {
            var list = &self.rows.items[row];
            return switch (layout) {
                .swap => list.swapRemove(i),
                .ordered => list.orderedRemove(i),
            };
        }

        pub fn dropSlice(self: *Self, layout: Reorder, row: I, i: I, n: I) []const T {
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

        pub fn move(self: *Self, layout: Reorder, row: I, item: T, to: I) void {
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

        pub fn moveAt(self: *Self, layout: Reorder, row: I, i: I, to: I) void {
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

        pub fn moveSlice(self: *Self, layout: Reorder, row: I, i: I, n: I, to: I) void {
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

        pub fn mutateAt(self: *Self, row: I, i: I) *T {
            const slice = self.rows.items[row].items;
            return &slice[i];
        }

        pub fn mutateSlice(self: *Self, row: I, i: I, n: I) []T {
            const slice = self.rows.items[row].items;
            assert(i <= slice.len and n <= slice.len - i);
            return slice[i..][0..n];
        }

        pub fn mutateLast(self: *Self, row: I) *T {
            const slice = self.rows.items[row].items;
            return &slice[slice.len - 1];
        }

        pub fn mutateLastSlice(self: *Self, row: I, n: I) []T {
            const slice = self.rows.items[row].items;
            assert(slice.len >= n);
            return slice[slice.len - n ..][0..n];
        }

        pub fn iterateMutable(self: *Self, row: I) iter.Iterator(T, .{ .mutable = true }) {
            return .{ .items = self.rows.items[row].items };
        }

        // Query Row ///////////////////////////////////////////////////////////

        pub fn query(self: *const Self) Query {
            return .{
                .ctx = self,
                .vtable = &query_vtable,
            };
        }

        const query_vtable = Query.VTable{
            .count = count,
            .contains = contains,
            .containsSlice = containsSlice,
            .orderOf = orderOf,
            .orderOfSlice = orderOfSlice,
            .view = view,
            .peekAt = peekAt,
            .peekSlice = peekSlice,
            .peekLast = peekLast,
            .peekLastSlice = peekLastSlice,
            .iterate = iterate,
            .iterateReverse = iterateReverse,
        };

        fn cast(ctx: *const anyopaque) *const Self {
            return @ptrCast(@alignCast(ctx));
        }

        fn count(ctx: *const anyopaque, row: I) I {
            return @intCast(cast(ctx).rows.items[row].items.len);
        }

        fn contains(ctx: *const anyopaque, row: I, item: T) bool {
            const slice = cast(ctx).rows.items[row].items;
            return utils.indexOf(slice, item) != null;
        }

        fn containsSlice(ctx: *const anyopaque, row: I, items: []const T) bool {
            const slice = cast(ctx).rows.items[row].items;
            return utils.indexOfSlice(slice, items) != null;
        }

        fn orderOf(ctx: *const anyopaque, row: I, item: T) I {
            const slice = cast(ctx).rows.items[row].items;
            return utils.indexOf(slice, item) orelse unreachable;
        }

        fn orderOfSlice(ctx: *const anyopaque, row: I, items: []const T) I {
            const slice = cast(ctx).rows.items[row].items;
            return utils.indexOfSlice(slice, items) orelse unreachable;
        }

        fn view(ctx: *const anyopaque, row: I) []const T {
            return cast(ctx).rows.items[row].items;
        }

        fn peekAt(ctx: *const anyopaque, row: I, i: I) T {
            return cast(ctx).rows.items[row].items[i];
        }

        fn peekSlice(ctx: *const anyopaque, row: I, i: I, n: I) []const T {
            const slice = cast(ctx).rows.items[row].items;
            assert(i <= slice.len and n <= slice.len - i);
            return slice[i..][0..n];
        }

        fn peekLast(ctx: *const anyopaque, row: I) T {
            const slice = cast(ctx).rows.items[row].items;
            assert(slice.len > 0);
            return slice[slice.len - 1];
        }

        fn peekLastSlice(ctx: *const anyopaque, row: I, n: I) []const T {
            const slice = cast(ctx).rows.items[row].items;
            assert(slice.len >= n);
            return slice[slice.len - n ..][0..n];
        }

        fn iterate(ctx: *const anyopaque, row: I) iter.Iterator(T, .{}) {
            const slice = cast(ctx).rows.items[row].items;
            return .{ .items = slice };
        }

        fn iterateReverse(ctx: *const anyopaque, row: I) iter.Iterator(T, .{ .reverse = true }) {
            const slice = cast(ctx).rows.items[row].items;
            return .{ .items = slice };
        }
    };
}

test "MutableSparseRows: Query" {
    var row0: [3]u8 = .{ 1, 2, 3 };
    var row1: [2]u8 = .{ 4, 5 };
    var rows: [2]std.ArrayListUnmanaged(u8) = .{
        std.ArrayListUnmanaged(u8).initBuffer(&row0),
        std.ArrayListUnmanaged(u8).initBuffer(&row1),
    };
    rows[0].items.len = 3;
    rows[1].items.len = 2;
    var sparse = MutableSparseRows(u8, .{}){};
    sparse.rows.items = &rows;

    try testing.expectEqual(3, sparse.query().count(0));
    try testing.expectEqual(false, sparse.query().contains(0, 8));
    try testing.expectEqual(true, sparse.query().contains(1, 5));
    try testing.expectEqual(false, sparse.query().containsSlice(0, &.{ 1, 3 }));
    try testing.expectEqual(true, sparse.query().containsSlice(0, &.{ 2, 3 }));
    try testing.expectEqual(1, sparse.query().orderOf(0, 2));
    try testing.expectEqual(1, sparse.query().orderOfSlice(0, &.{ 2, 3 }));
    try testing.expectEqualSlices(u8, &[_]u8{ 4, 5 }, sparse.query().view(1));
    try testing.expectEqual(3, sparse.query().peekAt(0, 2));
    try testing.expectEqualSlices(u8, &[_]u8{ 2, 3 }, sparse.query().peekSlice(0, 1, 2));
    try testing.expectEqual(3, sparse.query().peekLast(0));
    try testing.expectEqualSlices(u8, &[_]u8{ 2, 3 }, sparse.query().peekLastSlice(0, 2));
    try testing.expectEqualSlices(u8, &[_]u8{ 4, 5 }, sparse.query().iterate(1).items);

    var it = sparse.query().iterateReverse(1);
    for (&[_]u8{ 5, 4 }) |expected| try testing.expectEqual(expected, it.next());
    try testing.expectEqual(null, it.next());
}

test "MutableSparseRows: mutate" {
    var rows = MutableSparseRows(u8, .{}){};
    defer rows.deinit(test_alloc);

    const r0 = try rows.claimRow(test_alloc);
    try testing.expectEqual(0, rows.query().count(r0));

    try rows.append(test_alloc, r0, 1);
    try rows.appendSlice(test_alloc, r0, &.{ 2, 3 });
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3 }, rows.query().view(r0));

    try rows.insert(test_alloc, .ordered, r0, 1, 4);
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 4, 2, 3 }, rows.query().view(r0));

    try rows.insert(test_alloc, .swap, r0, 1, 5);
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 5, 2, 3, 4 }, rows.query().view(r0));

    try rows.insertSlice(test_alloc, .ordered, r0, 1, &.{ 6, 7 });
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 6, 7, 5, 2, 3, 4 }, rows.query().view(r0));

    try rows.insertSlice(test_alloc, .swap, r0, 1, &.{ 8, 9 });
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 8, 9, 5, 2, 3, 4, 6, 7 }, rows.query().view(r0));

    try testing.expectEqual(7, rows.pop(r0));
    try testing.expectEqualSlices(u8, &[_]u8{ 4, 6 }, rows.popSlice(r0, 2));
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 8, 9, 5, 2, 3 }, rows.query().view(r0));

    rows.drop(.ordered, r0, 9);
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 8, 5, 2, 3 }, rows.query().view(r0));

    rows.drop(.swap, r0, 8);
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 3, 5, 2 }, rows.query().view(r0));

    try testing.expectEqual(3, rows.dropAt(.swap, r0, 1));
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 5 }, rows.query().view(r0));

    try testing.expectEqual(2, rows.dropAt(.ordered, r0, 1));
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 5 }, rows.query().view(r0));

    try rows.appendSlice(test_alloc, r0, &.{ 6, 7 });
    try rows.insertSlice(test_alloc, .ordered, r0, 1, &.{ 2, 3, 4 });

    try testing.expectEqualSlices(u8, &[_]u8{ 2, 3 }, rows.dropSlice(.ordered, r0, 1, 2));
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 4, 5, 6, 7 }, rows.query().view(r0));

    try testing.expectEqualSlices(u8, &[_]u8{ 1, 4 }, rows.dropSlice(.swap, r0, 0, 2));
    try testing.expectEqualSlices(u8, &[_]u8{ 6, 7, 5 }, rows.query().view(r0));

    rows.mutateAt(r0, 0).* += 2;
    rows.mutateSlice(r0, 1, 2)[1] += 1;
    try testing.expectEqualSlices(u8, &[_]u8{ 8, 7, 6 }, rows.query().view(r0));

    rows.mutateLast(r0).* -= 4;
    try testing.expectEqual(2, rows.query().peekLast(r0));

    rows.mutateLastSlice(r0, 2)[0] -= 2;
    try testing.expectEqualSlices(u8, &[_]u8{ 8, 5, 2 }, rows.query().view(r0));

    const r1 = try rows.claimRowWithSlice(test_alloc, &.{ 1, 2, 3, 4, 5 });
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4, 5 }, rows.query().view(r1));

    rows.move(.swap, r1, 2, 3);
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 4, 3, 2, 5 }, rows.query().view(r1));

    rows.move(.ordered, r1, 4, 4);
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 3, 2, 5, 4 }, rows.query().view(r1));

    rows.moveAt(.swap, r1, 0, 4);
    try testing.expectEqualSlices(u8, &[_]u8{ 4, 3, 2, 5, 1 }, rows.query().view(r1));

    rows.moveAt(.ordered, r1, 1, 3);
    try testing.expectEqualSlices(u8, &[_]u8{ 4, 2, 5, 3, 1 }, rows.query().view(r1));

    rows.moveSlice(.swap, r1, 0, 2, 2);
    try testing.expectEqualSlices(u8, &[_]u8{ 5, 3, 4, 2, 1 }, rows.query().view(r1));

    rows.moveSlice(.swap, r1, 2, 2, 0);
    try testing.expectEqualSlices(u8, &[_]u8{ 4, 2, 5, 3, 1 }, rows.query().view(r1));

    rows.moveSlice(.ordered, r1, 0, 2, 3);
    try testing.expectEqualSlices(u8, &[_]u8{ 5, 3, 1, 4, 2 }, rows.query().view(r1));

    rows.moveSlice(.ordered, r1, 2, 2, 1);
    try testing.expectEqualSlices(u8, &[_]u8{ 5, 1, 4, 3, 2 }, rows.query().view(r1));

    rows.releaseRow(test_alloc, r1);
    try testing.expectEqual(r1, try rows.claimRow(test_alloc));
    try testing.expectEqual(0, rows.query().count(r1));

    try rows.appendSlice(test_alloc, r1, &.{ 2, 3 });
    var it = rows.iterateMutable(r1);
    while (it.next()) |item| item.* *= 2;
    try testing.expectEqualSlices(u8, &[_]u8{ 4, 6 }, rows.query().view(r1));
}

fn RowsUtils(comptime T: type, comptime options: SparseRowsOptions(T)) type {
    const I = options.Indexer;
    const eqlFn = comptime options.equalFn orelse std.meta.eql;
    const equatable = switch (@typeInfo(T)) {
        .Struct, .ErrorUnion, .Union, .Array, .Vector, .Pointer, .Optional => false,
        else => true,
    };

    return struct {
        pub fn indexOf(haystack: []const T, needle: T) ?I {
            if (comptime equatable and options.equalFn == null) {
                return if (mem.indexOfScalar(T, haystack, needle)) |i| @intCast(i) else null;
            } else {
                for (haystack.items, 0..) |t, i| {
                    if (eqlFn(t, needle)) return @intCast(i);
                }
                return null;
            }
        }

        pub fn indexOfSlice(haystack: []const T, needle: []const T) ?I {
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

pub fn SparseRowsQuery(comptime I: type, comptime T: type) type {
    return struct {
        const Self = @This();

        ctx: *const anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            count: *const fn (ctx: *const anyopaque, row: I) I,
            contains: *const fn (ctx: *const anyopaque, row: I, item: T) bool,
            containsSlice: *const fn (ctx: *const anyopaque, row: I, items: []const T) bool,
            orderOf: *const fn (ctx: *const anyopaque, row: I, item: T) I,
            orderOfSlice: *const fn (ctx: *const anyopaque, row: I, items: []const T) I,
            view: *const fn (ctx: *const anyopaque, row: I) []const T,
            peekAt: *const fn (ctx: *const anyopaque, row: I, i: I) T,
            peekSlice: *const fn (ctx: *const anyopaque, row: I, i: I, n: I) []const T,
            peekLast: *const fn (ctx: *const anyopaque, row: I) T,
            peekLastSlice: *const fn (ctx: *const anyopaque, row: I, n: I) []const T,
            iterate: *const fn (ctx: *const anyopaque, row: I) iter.Iterator(T, .{}),
            iterateReverse: *const fn (ctx: *const anyopaque, row: I) iter.Iterator(T, .{ .reverse = true }),
        };

        pub inline fn count(self: Self, row: I) I {
            return self.vtable.count(self.ctx, row);
        }

        pub inline fn contains(self: Self, row: I, item: T) bool {
            return self.vtable.contains(self.ctx, row, item);
        }

        pub inline fn containsSlice(self: Self, row: I, items: []const T) bool {
            return self.vtable.containsSlice(self.ctx, row, items);
        }

        pub inline fn orderOf(self: Self, row: I, item: T) I {
            return self.vtable.orderOf(self.ctx, row, item);
        }

        pub inline fn orderOfSlice(self: Self, row: I, items: []const T) I {
            return self.vtable.orderOfSlice(self.ctx, row, items);
        }

        pub inline fn view(self: Self, row: I) []const T {
            return self.vtable.view(self.ctx, row);
        }

        pub inline fn peekAt(self: Self, row: I, i: I) T {
            return self.vtable.peekAt(self.ctx, row, i);
        }

        pub inline fn peekSlice(self: Self, row: I, i: I, n: I) []const T {
            return self.vtable.peekSlice(self.ctx, row, i, n);
        }

        pub inline fn peekLast(self: Self, row: I) T {
            return self.vtable.peekLast(self.ctx, row);
        }

        pub inline fn peekLastSlice(self: Self, row: I, n: I) []const T {
            return self.vtable.peekLastSlice(self.ctx, row, n);
        }

        pub inline fn iterate(self: Self, row: I) iter.Iterator(T, .{}) {
            return self.vtable.iterate(self.ctx, row);
        }

        pub inline fn iterateReverse(self: Self, row: I) iter.Iterator(T, .{ .reverse = true }) {
            return self.vtable.iterateReverse(self.ctx, row);
        }
    };
}
