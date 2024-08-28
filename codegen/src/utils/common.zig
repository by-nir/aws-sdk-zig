const std = @import("std");

pub const DefaultIndexer = u32;

pub fn Handle(comptime Indexer: type) type {
    return enum(Indexer) {
        none = std.math.maxInt(Indexer),
        _,

        pub fn of(i: Indexer) @This() {
            return @enumFromInt(i);
        }
    };
}

pub fn RangeHandle(comptime Indexer: type) type {
    return packed struct {
        const Self = @This();

        offset: Indexer,
        length: Indexer,

        pub const empty = Self{ .offset = 0, .length = 0 };

        pub fn isEmpty(self: Self) bool {
            return self.length == 0;
        }
    };
}

pub const Reorder = enum { ordered, swap };
