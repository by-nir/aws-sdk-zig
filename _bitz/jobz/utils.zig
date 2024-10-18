const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const Delegate = @import("task.zig").Delegate;

pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        first: ?*Node(T) = null,
        last: ?*Node(T) = null,

        pub fn deinit(self: Self, allocator: Allocator, comptime with_values: bool) void {
            const node = self.first orelse return;
            node.deinit(allocator, with_values);
        }

        pub fn put(self: *Self, node: *Node(T)) void {
            if (self.last) |last| last.next = node else self.first = node;
            self.last = node;
            node.next = null;
            node.children = .{};
        }

        pub fn isEmpty(self: *Self) bool {
            return self.first == null;
        }

        pub fn peek(self: *Self) ?*Node(T) {
            return self.first;
        }

        pub fn take(self: *Self) ?*Node(T) {
            const node = self.first orelse return null;
            self.first = node.next;
            if (node.next == null) self.last = null else node.next = null;
            return node;
        }

        pub fn dropNext(self: *Self) void {
            const node = self.first orelse return;
            self.first = node.next;
            if (node.next == null) self.last = null else node.next = null;
        }
    };
}

test "Queue" {
    var queue = Queue(usize){};
    defer queue.deinit(test_alloc, false);

    try testing.expectEqual(null, queue.peek());
    try testing.expectEqual(null, queue.take());
    try testing.expectEqual(true, queue.isEmpty());

    const n0 = try test_alloc.create(Node(usize));
    defer test_alloc.destroy(n0);
    n0.* = .{ .value = 100 };
    queue.put(n0);

    try testing.expectEqual(100, queue.peek().?.value);
    try testing.expectEqual(false, queue.isEmpty());

    try testing.expectEqual(100, queue.take().?.value);
    try testing.expectEqual(null, queue.peek());
    try testing.expectEqual(null, queue.take());
    try testing.expectEqual(true, queue.isEmpty());

    const n1 = try test_alloc.create(Node(usize));
    defer test_alloc.destroy(n1);
    n1.* = .{ .value = 101 };
    queue.put(n1);

    queue.put(n0);

    const n2 = try test_alloc.create(Node(usize));
    defer test_alloc.destroy(n2);
    n2.* = .{ .value = 102 };
    queue.put(n2);

    try testing.expectEqual(101, queue.take().?.value);
    queue.dropNext(); // 100
    try testing.expectEqual(102, queue.take().?.value);
    try testing.expectEqual(null, queue.take());

    // Tests that the deinit also applies to the nodes
    queue.put(try test_alloc.create(Node(usize)));
    queue.put(try test_alloc.create(Node(usize)));
}

pub fn Node(comptime T: type) type {
    return struct {
        const Self = @This();

        value: T,
        next: ?*Self = null,
        children: Queue(T) = .{},

        pub fn init(allocator: Allocator, value: T) !*Self {
            const node = try allocator.create(Node(T));
            node.* = .{ .value = value };
            return node;
        }

        pub fn deinit(self: *Self, allocator: Allocator, comptime with_values: bool) void {
            var next: ?*Self = self;
            self.children.deinit(allocator, with_values);
            while (next) |node| {
                next = node.next;
                if (with_values) node.value.deinit(allocator);
                allocator.destroy(node);
            }
        }

        pub fn put(self: *Self, node: *Self) void {
            self.children.put(node);
        }
    };
}

test "Node.deinit" {
    var gpa: std.heap.GeneralPurposeAllocator(.{
        .never_unmap = true,
        .retain_metadata = true,
    }) = .{};
    const alloc = gpa.allocator();

    var next: ?*Node(usize) = null;
    for (0..3) |i| {
        const node = try alloc.create(Node(usize));
        node.* = .{ .value = i, .next = next };
        next = node;
    }

    next.?.deinit(alloc, false);
    try testing.expectEqual(.ok, gpa.deinit());
}

test "Node.deinit with values" {
    const Value = struct {
        id: usize,

        pub fn deinit(self: *const @This(), allocator: Allocator) void {
            allocator.destroy(self);
        }
    };

    var gpa: std.heap.GeneralPurposeAllocator(.{
        .never_unmap = true,
        .retain_metadata = true,
    }) = .{};
    const alloc = gpa.allocator();

    var next: ?*Node(*const Value) = null;
    for (0..3) |i| {
        const node = try alloc.create(Node(*const Value));
        const value = try alloc.create(Value);
        value.* = Value{ .id = i };
        node.* = .{ .value = value, .next = next };
        next = node;
    }

    next.?.deinit(alloc, true);
    try testing.expectEqual(.ok, gpa.deinit());
}

pub fn Pool(comptime T: type) type {
    return struct {
        const Self = @This();

        free: std.ArrayListUnmanaged(*T) = .{},
        createItem: *const fn (allocator: Allocator) anyerror!*T,
        destroyItem: *const fn (allocator: Allocator, item: *T) void,
        resetItem: ?*const fn (item: *T) void = null,

        pub fn deinit(self: *Self, allocator: Allocator) void {
            for (self.free.items) |item| self.destroyItem(allocator, item);
            self.free.deinit(allocator);
        }

        pub fn retain(self: *Self, allocator: Allocator) !*T {
            return self.free.popOrNull() orelse try self.createItem(allocator);
        }

        pub fn release(self: *Self, allocator: Allocator, item: *T) void {
            if (self.resetItem) |reset| reset(item);
            self.free.append(allocator, item) catch self.destroyItem(allocator, item);
        }
    };
}

test "Pool" {
    const actions = struct {
        fn create(allocator: Allocator) !*usize {
            const item = try allocator.create(usize);
            item.* = 0;
            return item;
        }

        fn destory(allocator: Allocator, item: *usize) void {
            allocator.destroy(item);
        }
    };

    var pool = Pool(usize){
        .createItem = actions.create,
        .destroyItem = actions.destory,
    };
    defer pool.deinit(test_alloc);

    var n0: ?*usize = try pool.retain(test_alloc);
    errdefer if (n0) |n| test_alloc.destroy(n);
    n0.?.* = 100;

    var n1: ?*usize = try pool.retain(test_alloc);
    errdefer if (n1) |n| test_alloc.destroy(n);
    n1.?.* = 101;

    pool.release(test_alloc, n0.?);
    n0 = null;

    n0 = try pool.retain(test_alloc);
    try testing.expectEqualDeep(100, n0.?.*);

    var n2: ?*usize = try pool.retain(test_alloc);
    errdefer if (n2) |n| test_alloc.destroy(n);
    n2.?.* = 102;

    pool.release(test_alloc, n1.?);
    n1 = null;
    pool.release(test_alloc, n0.?);
    n0 = null;
    pool.release(test_alloc, n2.?);
    n2 = null;

    try testing.expectEqualDeep(101, pool.free.items[0].*);
    try testing.expectEqualDeep(100, pool.free.items[1].*);
    try testing.expectEqualDeep(102, pool.free.items[2].*);
}

// https://github.com/ziglang/zig/issues/19858#issuecomment-2119335045
pub const ComptimeTag = enum(usize) {
    invalid = 0,
    _,

    pub fn of(comptime input: anytype) ComptimeTag {
        const producer = struct {
            inline fn id(comptime value: anytype) *const anyopaque {
                const Unique = struct {
                    var target: u8 = undefined;
                    comptime {
                        _ = value;
                    }
                };
                return comptime @ptrCast(&Unique.target);
            }
        };
        return @enumFromInt(@intFromPtr(comptime producer.id(input)));
    }

    pub fn ref(input: anytype) ComptimeTag {
        if (@typeInfo(@TypeOf(input)) != .pointer) @compileError("Use ComptimeTag.of instead");
        return @enumFromInt(@intFromPtr(input));
    }
};

/// Returns a `*T` or the unmodified type if it’s already a pointer.
pub fn Reference(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => T,
        else => *T,
    };
}

test "Reference" {
    try testing.expectEqual(*const bool, Reference(*const bool));
    try testing.expectEqual(*bool, Reference(*bool));
    try testing.expectEqual([]bool, Reference([]bool));
    try testing.expectEqual(*bool, Reference(bool));
}

/// Returns a `?T` or the unmodified type if it’s already optional.
pub fn Optional(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => T,
        else => ?T,
    };
}

test "Optional" {
    try testing.expectEqual(?bool, Optional(?bool));
    try testing.expectEqual(?bool, Optional(bool));
}

/// Returns a `anyerror!T` or the unmodified type if it’s already an error union.
pub fn Failable(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .error_union => T,
        else => anyerror!T,
    };
}

test "Failable" {
    try testing.expectEqual(error{Boom}!bool, Failable(error{Boom}!bool));
    try testing.expectEqual(anyerror!bool, Failable(bool));
}

/// Extracts the payload from an error union or return the unmodified type otherwise.
pub fn StripError(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .error_union => |t| t.payload,
        else => T,
    };
}

test "StripError" {
    try testing.expectEqual(bool, StripError(error{Boom}!bool));
    try testing.expectEqual(bool, StripError(bool));
}

/// Extracts the payload from an optional, pointer, or error union; otherwise returns the unmodified type.
pub fn Payload(comptime T: type) type {
    return switch (@typeInfo(T)) {
        inline .pointer, .optional => |t| t.child,
        .error_union => |t| t.payload,
        else => T,
    };
}

test "Payload" {
    try testing.expectEqual(bool, Payload(anyerror!bool));
    try testing.expectEqual(bool, Payload(?bool));
    try testing.expectEqual(bool, Payload(*const bool));
    try testing.expectEqual(bool, Payload(bool));
}

pub fn TupleFiller(comptime Tuple: type) type {
    const len = @typeInfo(Tuple).@"struct".fields.len;
    return struct {
        const Self = @This();

        tuple: Tuple = undefined,

        pub inline fn append(self: *Self, i: *usize, value: anytype) void {
            comptime std.debug.assert(i.* < len);
            const field: []const u8 = comptime std.fmt.comptimePrint("{d}", .{i.*});
            @field(self.tuple, field) = value;
            comptime i.* += 1;
        }

        pub inline fn consume(self: Self, i: *usize) Tuple {
            comptime std.debug.assert(i.* == len);
            return self.tuple;
        }
    };
}

test "TuppleFiller" {
    comptime var shift: usize = 0;
    const Tup = struct { usize, bool, f32 };
    var tuple = TupleFiller(Tup){};
    tuple.append(&shift, @as(usize, 108));
    tuple.append(&shift, true);
    tuple.append(&shift, @as(f32, 1.08));
    try testing.expectEqualDeep(Tup{ 108, true, 1.08 }, tuple.consume(&shift));
}

pub inline fn logOrPanic(comptime fmt: []const u8, args: anytype) void {
    if (std.debug.runtime_safety) {
        std.log.err(fmt, args);
        unreachable;
    } else {
        std.debug.panic(fmt, args);
    }
}
