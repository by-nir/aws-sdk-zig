const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;

pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        first: ?*ChainNode(T) = null,
        last: ?*ChainNode(T) = null,

        pub fn deinit(self: Self, allocator: Allocator, comptime values: bool) void {
            const node = self.first orelse return;
            if (values) node.deinitChainAndValues(allocator) else node.deinitChain(allocator);
        }

        pub fn put(self: *Self, node: *ChainNode(T)) void {
            if (self.last) |last| last.next = node else self.first = node;
            self.last = node;
            node.next = null;
        }

        pub fn take(self: *Self) ?*ChainNode(T) {
            const node = self.first orelse return null;
            self.first = node.next;
            if (node.next == null) self.last = null else node.next = null;
            return node;
        }
    };
}

test "Queue" {
    var queue = Queue(usize){};
    defer queue.deinit(test_alloc, false);

    try testing.expectEqual(null, queue.take());

    const n0 = try test_alloc.create(ChainNode(usize));
    defer test_alloc.destroy(n0);
    n0.* = .{ .value = 100 };
    queue.put(n0);

    try testing.expectEqual(100, queue.take().?.value);
    try testing.expectEqual(null, queue.take());

    const n1 = try test_alloc.create(ChainNode(usize));
    defer test_alloc.destroy(n1);
    n1.* = .{ .value = 101 };
    queue.put(n1);

    queue.put(n0);

    const n2 = try test_alloc.create(ChainNode(usize));
    defer test_alloc.destroy(n2);
    n2.* = .{ .value = 102 };
    queue.put(n2);

    try testing.expectEqual(101, queue.take().?.value);
    try testing.expectEqual(100, queue.take().?.value);
    try testing.expectEqual(102, queue.take().?.value);
    try testing.expectEqual(null, queue.take());

    // Tests that the deinit also applies to the nodes
    queue.put(try test_alloc.create(ChainNode(usize)));
    queue.put(try test_alloc.create(ChainNode(usize)));
}

pub fn Pool(comptime T: type) type {
    return struct {
        const Self = @This();

        next: ?*ChainNode(T) = null,
        clearValue: ?*const fn (node: *ChainNode(T)) void = null,

        pub fn deinit(self: Self, allocator: Allocator, comptime values: bool) void {
            const node = self.next orelse return;
            if (values) node.deinitChainAndValues(allocator) else node.deinitChain(allocator);
        }

        pub fn retain(self: *Self, allocator: Allocator) !*ChainNode(T) {
            const node = if (self.next) |n| blk: {
                self.next = n.next;
                break :blk n;
            } else blk: {
                const n = try allocator.create(ChainNode(T));
                if (self.clearValue) |f| f(n);
                break :blk n;
            };

            node.next = null;
            return node;
        }

        pub fn release(self: *Self, node: *ChainNode(T)) void {
            if (self.clearValue) |f| f(node);
            node.next = self.next;
            self.next = node;
        }
    };
}

test "Pool" {
    var pool = Pool(usize){};
    defer pool.deinit(test_alloc, false);

    var n0: ?*ChainNode(usize) = try pool.retain(test_alloc);
    errdefer if (n0) |n| test_alloc.destroy(n);
    n0.?.value = 100;

    var n1: ?*ChainNode(usize) = try pool.retain(test_alloc);
    errdefer if (n1) |n| test_alloc.destroy(n);
    n1.?.value = 101;

    pool.release(n0.?);
    n0 = null;

    n0 = try pool.retain(test_alloc);
    try testing.expectEqual(100, n0.?.value);

    var n2: ?*ChainNode(usize) = try pool.retain(test_alloc);
    errdefer if (n2) |n| test_alloc.destroy(n);
    n2.?.value = 102;

    pool.release(n1.?);
    n1 = null;
    pool.release(n0.?);
    n0 = null;
    pool.release(n2.?);
    n2 = null;

    var node = pool.next orelse return error.ExpectedNode;
    try testing.expectEqualDeep(102, node.value);

    node = node.next orelse return error.ExpectedNode;
    try testing.expectEqualDeep(100, node.value);

    node = node.next orelse return error.ExpectedNode;
    try testing.expectEqualDeep(101, node.value);
}

pub fn ChainNode(comptime T: type) type {
    return struct {
        value: T,
        next: ?*@This() = null,

        pub fn deinitChain(self: *@This(), allocator: Allocator) void {
            var next: ?*@This() = self;
            while (next) |node| {
                next = node.next;
                allocator.destroy(node);
            }
        }

        pub fn deinitChainAndValues(self: *@This(), allocator: Allocator) void {
            var next: ?*@This() = self;
            while (next) |node| {
                next = node.next;
                node.value.deinit(allocator);
                allocator.destroy(node);
            }
        }
    };
}

test "node.deinitChain" {
    var gpa: std.heap.GeneralPurposeAllocator(.{ .safety = true }) = .{};
    const alloc = gpa.allocator();

    var next: ?*ChainNode(usize) = null;
    for (0..3) |i| {
        const node = try alloc.create(ChainNode(usize));
        node.* = .{ .value = i, .next = next };
        next = node;
    }

    next.?.deinitChain(alloc);
    try testing.expectEqual(.ok, gpa.deinit());
}

test "node.deinitChainAndValues" {
    const Value = struct {
        id: usize,

        pub fn deinit(self: *const @This(), allocator: Allocator) void {
            allocator.destroy(self);
        }
    };

    var gpa: std.heap.GeneralPurposeAllocator(.{ .safety = true }) = .{};
    const alloc = gpa.allocator();

    var next: ?*ChainNode(*const Value) = null;
    for (0..3) |i| {
        const node = try alloc.create(ChainNode(*const Value));
        const value = try alloc.create(Value);
        value.* = Value{ .id = i };
        node.* = .{ .value = value, .next = next };
        next = node;
    }

    next.?.deinitChainAndValues(alloc);
    try testing.expectEqual(.ok, gpa.deinit());
}
