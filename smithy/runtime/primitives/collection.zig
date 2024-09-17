const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;

pub fn Set(comptime T: type) type {
    const HashMap = if (T == []const u8) std.StringHashMapUnmanaged(void) else std.AutoHashMapUnmanaged(T, void);

    return struct {
        const Self = @This();
        pub const Item = T;
        pub const Indexer = HashMap.Size;
        pub const Iterator = HashMap.KeyIterator;

        internal: HashMap = .{},

        pub fn count(self: Self) Indexer {
            return self.internal.count();
        }

        pub fn contains(self: Self, item: T) bool {
            return self.internal.contains(item);
        }

        pub fn iterator(self: Self) Iterator {
            return self.internal.keyIterator();
        }
    };
}

test Set {
    var set = Set([]const u8){};
    errdefer set.internal.deinit(test_alloc);

    try testing.expectEqual(0, set.count());

    try testing.expectEqual(false, set.contains("foo"));
    try set.internal.putNoClobber(test_alloc, "foo", {});
    try testing.expectEqual(true, set.contains("foo"));
    try testing.expectEqual(1, set.count());

    try testing.expectEqual(false, set.contains("bar"));
    try set.internal.putNoClobber(test_alloc, "bar", {});
    try testing.expectEqual(true, set.contains("bar"));
    try testing.expectEqual(2, set.count());

    set.internal.deinit(test_alloc);
}

pub fn Map(comptime K: type, comptime V: type) type {
    const HashMap = switch (K) {
        []const u8 => std.StringHashMapUnmanaged(V),
        else => std.AutoHashMapUnmanaged(K, V),
    };

    return struct {
        const Self = @This();
        pub const Key = K;
        pub const Value = V;
        pub const Entry = HashMap.Entry;
        pub const Indexer = HashMap.Size;
        pub const Iterator = HashMap.Iterator;

        internal: HashMap = .{},

        pub fn count(self: Self) Indexer {
            return self.internal.count();
        }

        pub fn contains(self: Self, key: Key) bool {
            return self.internal.contains(key);
        }

        pub fn get(self: Self, key: Key) ?Value {
            return self.internal.get(key);
        }

        pub fn iterator(self: *const Self) Iterator {
            return self.internal.iterator();
        }

        pub fn keyIterator(self: Self) Iterator {
            return self.internal.keyIterator();
        }

        pub fn valueIterator(self: Self) Iterator {
            return self.internal.valueIterator();
        }
    };
}

test Map {
    var map = Map(u32, []const u8){};
    errdefer map.internal.deinit(test_alloc);

    try testing.expectEqual(0, map.count());

    try testing.expectEqual(false, map.contains(108));
    try map.internal.putNoClobber(test_alloc, 108, "foo");
    try testing.expectEqual(true, map.contains(108));
    try testing.expectEqual(1, map.count());

    try testing.expectEqual(false, map.contains(109));
    try map.internal.putNoClobber(test_alloc, 109, "bar");
    try testing.expectEqual(true, map.contains(109));
    try testing.expectEqual(2, map.count());

    try testing.expectEqual(null, map.get(107));
    try testing.expectEqualStrings("foo", map.get(108).?);
    try testing.expectEqualStrings("bar", map.get(109).?);

    map.internal.deinit(test_alloc);
}
