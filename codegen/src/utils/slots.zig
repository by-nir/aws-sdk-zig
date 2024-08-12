const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;

pub fn FixedSlots(comptime size: comptime_int) type {
    const Mask = usize;
    const Shift: type = std.math.Log2Int(Mask);
    const LEN = (size + @bitSizeOf(Mask) - 1) / @bitSizeOf(Mask);
    if (LEN > 1024) @compileError("FixedSlots supports up to 1024 slots, use DynamicSlots instead.");

    return struct {
        const Self = @This();
        pub const Indexer: type = std.math.IntFittingRange(0, size - 1);

        segments: [LEN]Mask = (&[_]Mask{0} ** LEN).*,

        pub const empty = Self{};
        pub const full = Self{ .segments = (&[_]Mask{1} ** LEN).* };

        pub fn takeFirst(self: *Self) ?Indexer {
            for (0..LEN) |i| {
                const mask = self.segments[@truncate(i)];
                const bit = firstBit(Indexer, Mask, mask) orelse continue;
                return self.take(@truncate(i), bit);
            }
            return null;
        }

        pub fn takeLast(self: *Self) ?Indexer {
            for (1..LEN + 1) |l| {
                const i: Indexer = @truncate(LEN - l);
                const bit = lastBit(Indexer, Mask, self.segments[i]) orelse continue;
                return self.take(@truncate(i), bit);
            }
            return null;
        }

        fn take(self: *Self, i: Indexer, bit: Indexer) Indexer {
            self.segments[i] &= ~bitMask(Indexer, Mask, Shift, bit);
            return compose(Indexer, Shift, i, bit);
        }

        pub fn put(self: *Self, index: usize) !void {
            std.debug.assert(index < size);
            const i = extractSegment(Indexer, Shift, @truncate(index));
            const mask = bitMask(Indexer, Mask, Shift, @truncate(index));
            std.debug.assert(self.segments[i] & mask == 0);
            self.segments[i] |= mask;
        }
    };
}

test "FixedSlots" {
    var slots = FixedSlots(256){};

    try testing.expectEqual(null, slots.takeLast());
    try slots.put(0);
    try slots.put(64);
    try slots.put(63);
    try testing.expectEqual(64, slots.takeLast());
    try testing.expectEqual(63, slots.takeLast());
    try testing.expectEqual(0, slots.takeLast());
    try testing.expectEqual(null, slots.takeLast());

    try testing.expectEqual(null, slots.takeFirst());
    try slots.put(0);
    try slots.put(64);
    try slots.put(63);
    try testing.expectEqual(0, slots.takeFirst());
    try testing.expectEqual(63, slots.takeFirst());
    try testing.expectEqual(64, slots.takeFirst());
    try testing.expectEqual(null, slots.takeFirst());
}

pub fn DynamicSlots(comptime Indexer: type) type {
    const INITIAL_CAPACITY = 16;
    const EMPTY = std.math.maxInt(Indexer);
    const Shift: type = std.math.Log2Int(Indexer);

    // The last index is reserved for the empty tag.
    const MAX_INDEX = std.math.maxInt(Indexer) - @bitSizeOf(Indexer);

    const Segment = struct {
        id: Indexer = 0,
        mask: Indexer = 0,
    };

    const Location = union(enum) {
        init,
        append,
        insert: Indexer,
        mutate: Indexer,
    };

    return struct {
        const Self = @This();

        capacity: Indexer = 0,
        len: Indexer = EMPTY,
        segments: [*]Segment = undefined,

        pub fn deinit(self: Self, allocator: Allocator) void {
            if (self.capacity > 0) allocator.free(self.segments[0..self.capacity]);
        }

        pub fn takeFirst(self: *Self) ?Indexer {
            if (self.len == EMPTY) return null;
            for (0..self.len) |i| {
                const segement = self.segments[@truncate(i)];
                const bit = firstBit(Indexer, Indexer, segement.mask) orelse continue;
                return take(self, @truncate(i), segement.id, bit);
            }
            return null;
        }

        pub fn takeLast(self: *Self) ?Indexer {
            if (self.len == EMPTY) return null;
            for (1..self.len + 1) |l| {
                const i: Indexer = @truncate(self.len - l);
                const segement = self.segments[i];
                const bit = lastBit(Indexer, Indexer, segement.mask) orelse continue;
                return take(self, @truncate(i), segement.id, bit);
            }
            return null;
        }

        fn take(self: *Self, i: Indexer, sid: Indexer, bit: Indexer) Indexer {
            self.segments[i].mask &= ~bitMask(Indexer, Indexer, Shift, bit);
            return compose(Indexer, Shift, sid, bit);
        }

        pub fn put(self: *Self, allocator: Allocator, index: Indexer) !void {
            std.debug.assert(index <= MAX_INDEX);
            const sid = extractSegment(Indexer, Shift, index);
            const segment = try self.mutateSegment(allocator, sid);
            const mask = bitMask(Indexer, Indexer, Shift, index);
            std.debug.assert(segment.* & mask == 0);
            segment.* |= mask;
        }

        fn mutateSegment(self: *Self, allocator: Allocator, sid: Indexer) !*Indexer {
            switch (self.searchSegment(sid)) {
                .init => {
                    try self.ensureCapacity(allocator, INITIAL_CAPACITY);
                    self.len = 1;
                    self.segments[0] = .{ .id = sid };
                    return &self.segments[0].mask;
                },
                .append => {
                    try self.ensureCapacity(allocator, self.len + 1);
                    defer self.len += 1;
                    self.segments[self.len] = .{ .id = sid };
                    return &self.segments[self.len].mask;
                },
                .insert => |i| {
                    try self.insert(allocator, i);
                    self.segments[i] = .{ .id = sid };
                    return &self.segments[i].mask;
                },
                .mutate => |i| return &self.segments[i].mask,
            }
        }

        fn searchSegment(self: Self, sid: Indexer) Location {
            if (self.len == EMPTY) return .init;

            var start_idx: usize = 0;
            var end_idx: usize = switch (self.len) {
                EMPTY => return .init,
                else => |i| i - 1,
            };

            while (start_idx < end_idx) {
                const mid_idx = start_idx + (end_idx - start_idx) / 2;
                const mid_val = self.segments[mid_idx].id;
                if (sid == mid_val) {
                    return .{ .mutate = @truncate(mid_idx) };
                } else if (sid < mid_val) {
                    end_idx = mid_idx;
                } else {
                    start_idx = mid_idx + 1;
                }
            }

            const val = self.segments[start_idx].id;
            if (sid == val) {
                return .{ .mutate = @truncate(start_idx) };
            } else if (sid < val) {
                return .{ .insert = @truncate(start_idx) };
            } else {
                return .append;
            }
        }

        fn insert(self: *Self, allocator: Allocator, i: Indexer) !void {
            try self.ensureCapacity(allocator, self.len + 1);
            std.mem.copyBackwards(
                Segment,
                self.segments[i + 1 .. self.len + 1],
                self.segments[i..self.len],
            );
            self.len += 1;
        }

        fn ensureCapacity(self: *Self, allocator: Allocator, required: Indexer) !void {
            if (self.capacity >= required) return;

            var new_size = switch (self.capacity) {
                0 => if (required & 0b1 == 0) required else required + 1,
                else => self.capacity * 2,
            };
            while (new_size < required) new_size *= 2;

            const old_bytes = self.segments[0..self.capacity];
            if (!allocator.resize(old_bytes, new_size)) {
                const new_bytes = try allocator.alloc(Segment, new_size);
                @memcpy(new_bytes[0..self.capacity], old_bytes);
                allocator.free(old_bytes);
                self.segments = new_bytes.ptr;
            }

            @memset(self.segments[self.capacity..new_size], .{});
            self.capacity = new_size;
        }
    };
}

test "DynamicSlots" {
    var slots = DynamicSlots(u32){};
    defer slots.deinit(test_alloc);

    try testing.expectEqual(null, slots.takeFirst());
    try slots.put(test_alloc, 32); // init
    try slots.put(test_alloc, 38); // mutate
    try slots.put(test_alloc, 8); // insert
    try slots.put(test_alloc, 108); // append
    try testing.expectEqual(8, slots.takeFirst());
    try testing.expectEqual(32, slots.takeFirst());
    try testing.expectEqual(38, slots.takeFirst());
    try testing.expectEqual(108, slots.takeFirst());
    try testing.expectEqual(null, slots.takeFirst());

    try testing.expectEqual(null, slots.takeLast());
    try slots.put(test_alloc, 32); // init
    try slots.put(test_alloc, 38); // mutate
    try slots.put(test_alloc, 8); // insert
    try slots.put(test_alloc, 108); // append
    try testing.expectEqual(108, slots.takeLast());
    try testing.expectEqual(38, slots.takeLast());
    try testing.expectEqual(32, slots.takeLast());
    try testing.expectEqual(8, slots.takeLast());
    try testing.expectEqual(null, slots.takeLast());
}

fn firstBit(comptime Indexer: type, comptime Mask: type, bits: Mask) ?Indexer {
    return switch (@ctz(bits)) {
        @bitSizeOf(Mask) => null,
        else => |zeros| zeros,
    };
}

fn lastBit(comptime Indexer: type, comptime Mask: type, bits: Mask) ?Indexer {
    return switch (@clz(bits)) {
        @bitSizeOf(Mask) => null,
        else => |zeros| @bitSizeOf(Mask) - 1 - zeros,
    };
}

fn extractSegment(comptime Indexer: type, comptime Shift: type, index: Indexer) Indexer {
    return index >> @bitSizeOf(Shift);
}

fn bitMask(comptime Indexer: type, comptime Mask: type, comptime Shift: type, index: Indexer) Mask {
    return @as(Mask, 1) << @as(Shift, @truncate(index));
}

fn compose(comptime Indexer: type, comptime Shift: type, part: Indexer, bit: Indexer) Indexer {
    return (part << @bitSizeOf(Shift)) | @as(Indexer, @truncate(bit));
}
