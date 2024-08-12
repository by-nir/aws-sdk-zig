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
        cursor: usize = 0,
        items: if (options.mutable) []T else []const T,

        const Self = @This();

        pub fn skip(self: *Self, count: usize) void {
            std.debug.assert(self.cursor + count <= self.items.len);
            self.cursor += count;
        }

        pub fn peek(self: Self) ?Item {
            if (self.cursor == self.items.len) return null;
            return self.getItem(self.cursor);
        }

        pub fn next(self: *Self) ?Item {
            if (self.cursor == self.items.len) return null;
            defer self.cursor += 1;
            return self.getItem(self.cursor);
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
