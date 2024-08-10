const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;

pub const Options = struct {};

pub fn Iterator(comptime T: type, comptime _: Options) type {
    return struct {
        cursor: usize = 0,
        items: []const T,

        const Self = @This();

        pub fn skip(self: *Self, count: usize) void {
            std.debug.assert(self.cursor + count <= self.items.len);
            self.cursor += count;
        }

        pub fn peek(self: Self) ?T {
            if (self.cursor == self.items.len) return null;
            return self.items[self.cursor];
        }

        pub fn next(self: *Self) ?T {
            if (self.cursor == self.items.len) return null;
            defer self.cursor += 1;
            return self.items[self.cursor];
        }

        pub fn reset(self: *Self) void {
            self.cursor = 0;
        }

        pub fn length(self: Self) usize {
            return self.items.len;
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
    var it = Iterator(u8, .{}){ .items = &.{} };
    try expectIterator(&it, u8, &.{});

    it = Iterator(u8, .{}){ .items = &.{ 1, 2, 3 } };
    try expectIterator(&it, u8, &.{ 1, 2, 3 });
}
