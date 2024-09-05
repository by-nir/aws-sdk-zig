const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;

pub fn Set(comptime T: type) type {
    const Map = if (T == []const u8) std.StringHashMapUnmanaged(void) else std.AutoHashMapUnmanaged(T, void);

    return struct {
        const Self = @This();
        pub const Size = Map.Size;
        pub const Iterator = Map.KeyIterator;

        map: Map = .{},

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.map.deinit(allocator);
        }

        pub fn ensureTotalCapacity(self: *Self, allocator: Allocator, new_size: Size) !void {
            try self.map.ensureTotalCapacity(allocator, new_size);
        }

        pub fn ensureUnusedCapacity(self: *Self, allocator: Allocator, additional_size: Size) !void {
            try self.map.ensureUnusedCapacity(allocator, additional_size);
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.map.clearRetainingCapacity();
        }

        pub fn clearAndFree(self: *Self, allocator: Allocator) void {
            self.map.clearAndFree(allocator);
        }

        pub fn capacity(self: Self) Size {
            return self.map.capacity();
        }

        pub fn count(self: Self) Size {
            return self.map.count();
        }

        pub fn contains(self: Self, item: T) bool {
            return self.map.contains(item);
        }

        pub fn iterator(self: Self) Iterator {
            return self.map.keyIterator();
        }

        pub fn put(self: *Self, allocator: Allocator, item: T) !void {
            try self.map.put(allocator, item, {});
        }

        pub fn putNoClobber(self: *Self, allocator: Allocator, item: T) !void {
            try self.map.putNoClobber(allocator, item, {});
        }

        pub fn putAssumeCapacity(self: *Self, allocator: Allocator, item: T) void {
            self.map.putAssumeCapacity(allocator, item, {});
        }

        pub fn putAssumeCapacityNoClobber(self: *Self, allocator: Allocator, item: T) void {
            self.map.putAssumeCapacityNoClobber(allocator, item, {});
        }

        pub fn remove(self: *Self, item: T) bool {
            return self.map.remove(item);
        }

        pub fn jsonStringify(self: Self, jw: anytype) !void {
            try jw.beginArray();

            var it = self.map.keyIterator();
            while (it.next()) |item| {
                try jw.write(item);
            }

            try jw.endArray();
        }
    };
}

test "SetUnmanaged" {
    var set = Set(u32){};
    errdefer set.deinit(test_alloc);

    try testing.expectEqual(0, set.count());
    try testing.expectEqual(0, set.capacity());
    try testing.expectEqual(false, set.contains(108));
    try testing.expectEqual(false, set.remove(108));

    try set.put(test_alloc, 108);
    try set.put(test_alloc, 109);
    try testing.expectEqual(true, set.contains(108));
    try testing.expectEqual(2, set.count());
    try testing.expect(set.capacity() > 0);

    try testing.expect(set.capacity() - set.count() < 30);
    try set.ensureUnusedCapacity(test_alloc, 30);
    try testing.expect(set.capacity() - set.count() >= 30);

    try set.ensureTotalCapacity(test_alloc, 256);
    try testing.expect(set.capacity() >= 256);

    var it = set.iterator();
    try testing.expectEqual(108, it.next().?.*);
    try testing.expectEqual(109, it.next().?.*);

    try testing.expectEqual(true, set.remove(108));
    try testing.expectEqual(1, set.count());

    const capacity = set.capacity();
    set.clearRetainingCapacity();
    try testing.expectEqual(0, set.count());
    try testing.expectEqual(capacity, set.capacity());

    try set.put(test_alloc, 108);
    set.clearAndFree(test_alloc);
    try testing.expectEqual(0, set.count());
    try testing.expect(set.capacity() < capacity);

    set.deinit(test_alloc);
}
