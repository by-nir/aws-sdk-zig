const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;

pub const IteratorOptions = struct {
    reverse: bool = false,
    mutable: bool = false,
};

pub fn Iterator(comptime T: type, comptime options: IteratorOptions) type {
    const Item = if (options.mutable) *T else T;
    return struct {
        const Self = @This();

        cursor: usize = 0,
        items: if (options.mutable) []T else []const T,

        pub fn peek(self: Self) ?Item {
            if (self.cursor == self.items.len) return null;
            return self.getItem(self.cursor);
        }

        pub fn next(self: *Self) ?Item {
            if (self.cursor == self.items.len) return null;
            defer self.cursor += 1;
            return self.getItem(self.cursor);
        }

        pub fn skip(self: *Self, count: usize) void {
            std.debug.assert(self.cursor + count <= self.items.len);
            self.cursor += count;
        }

        pub fn reset(self: *Self) void {
            self.cursor = 0;
        }

        pub fn length(self: Self) usize {
            return self.items.len;
        }

        fn getItem(self: Self, cursor: usize) Item {
            const index = if (options.reverse) self.items.len - 1 - cursor else cursor;
            return if (options.mutable) &self.items[index] else self.items[index];
        }
    };
}

pub fn expectIterator(iterator: anytype, comptime T: type, items: []const T) !void {
    try testing.expectEqual(items.len, iterator.length());

    for (items) |item| {
        try testing.expectEqualDeep(item, iterator.next());
    }

    try testing.expectEqual(null, iterator.next());
}

test "Iterator" {
    var it = Iterator(u8, .{}){
        .items = &.{},
    };
    try expectIterator(&it, u8, &.{});

    it = Iterator(u8, .{}){
        .items = &.{ 1, 2, 3 },
    };
    try expectIterator(&it, u8, &.{ 1, 2, 3 });

    var it_rev = Iterator(u8, .{
        .reverse = true,
    }){
        .items = &.{ 1, 2, 3 },
    };
    try expectIterator(&it_rev, u8, &.{ 3, 2, 1 });

    var items: [1]u8 = .{1};
    var it_mut = Iterator(u8, .{
        .mutable = true,
    }){
        .items = &items,
    };

    const item: *u8 = it_mut.next().?;
    try testing.expectEqualDeep(1, item.*);
    item.* = 2;
    try testing.expectEqualDeep(2, items[0]);
}

pub fn Walker(comptime T: type, comptime Cursor: type) type {
    return struct {
        const Self = @This();

        cursor: Cursor,
        ctx: *const anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            peek: *const fn (ctx: *const anyopaque, cursor: Cursor) ?T,
            next: *const fn (ctx: *const anyopaque, cursor: *Cursor) ?T,
            skip: *const fn (ctx: *const anyopaque, cursor: *Cursor) void,
        };

        pub inline fn peek(self: Self) ?T {
            return self.vtable.peek(self.ctx, self.cursor);
        }

        pub inline fn next(self: *Self) ?T {
            return self.vtable.next(self.ctx, &self.cursor);
        }

        pub inline fn skip(self: *Self) void {
            self.vtable.next(self.ctx, &self.cursor);
        }
    };
}

test "Walker" {
    const Tester = struct {
        pub const vtable = Walker(usize, usize).VTable{
            .peek = peek,
            .next = next,
            .skip = skip,
        };

        fn peek(ctx: *const anyopaque, cursor: usize) ?usize {
            const target = cast(ctx);
            return if (cursor <= target) cursor else null;
        }

        fn next(ctx: *const anyopaque, cursor: *usize) ?usize {
            const target = cast(ctx);
            if (cursor.* > target) return null;
            defer cursor.* += 1;
            return cursor.*;
        }

        fn skip(_: *const anyopaque, cursor: *usize) void {
            cursor.* += 1;
        }

        fn cast(ctx: *const anyopaque) usize {
            return @as(*const usize, @ptrCast(@alignCast(ctx))).*;
        }
    };

    var walker = Walker(usize, usize){
        .cursor = 0,
        .ctx = &@as(usize, 2),
        .vtable = &Tester.vtable,
    };

    for (0..3) |i| try testing.expectEqual(i, walker.next());
    try testing.expectEqual(null, walker.next());
}
