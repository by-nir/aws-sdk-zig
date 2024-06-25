const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const tsk = @import("task.zig");

const PendingTask = struct {
    evaluator: TaskEvaluator.FactoryFn,
    input: ?*const anyopaque,
};

const TaskEvaluator = struct {
    invoke: *const fn (delegate: tsk.TaskDelegate, input: ?*const anyopaque) anyerror!void,
    deinit: *const fn (allocator: Allocator, input: *const anyopaque) void,

    pub const FactoryFn = *const fn () TaskEvaluator;

    pub fn of(comptime task: tsk.Task) FactoryFn {
        return struct {
            fn invoke(delegate: tsk.TaskDelegate, in: ?*const anyopaque) anyerror!void {
                const input: *const task.In(false) = @alignCast(@ptrCast(in));
                return task.invoke(delegate, input.*);
            }

            fn deinit(allocator: Allocator, in: *const anyopaque) void {
                std.debug.assert(task.input != null);
                const input: *const task.In(false) = @alignCast(@ptrCast(in));
                allocator.destroy(input);
            }

            pub fn factory() TaskEvaluator {
                return .{
                    .invoke = invoke,
                    .deinit = deinit,
                };
            }
        }.factory;
    }
};

pub const Schedule = struct {
    allocator: Allocator,
    queue: Queue(PendingTask) = .{},
    task_pool: Pool(PendingTask) = .{},

    pub fn init(allocator: Allocator) Schedule {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: Schedule) void {
        self.queue.deinit(self.allocator);
        self.task_pool.deinit(self.allocator);
    }

    pub fn scheduleTask(self: *Schedule, comptime task: tsk.Task, input: task.In(false)) !void {
        const input_dupe: ?*task.In(false) = if (task.input != null) blk: {
            const dupe = try self.allocator.create(task.In(false));
            dupe.* = input;
            break :blk dupe;
        } else null;
        errdefer if (input_dupe) |dupe| self.allocator.destroy(dupe);

        const node = try self.task_pool.retain(self.allocator);
        node.value = PendingTask{
            .input = input_dupe,
            .evaluator = TaskEvaluator.of(task),
        };
        self.queue.put(node);
    }

    pub fn run(self: *Schedule) !void {
        while (self.queue.take()) |node| {
            const task = node.value;
            self.task_pool.release(node);

            const evaluator = task.evaluator();
            defer if (task.input) |input| evaluator.deinit(self.allocator, input);

            const delegate = tsk.TaskDelegate{};
            try evaluator.invoke(delegate, task.input);
        }
    }
};

fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        first: ?*Node(T) = null,
        last: ?*Node(T) = null,

        pub fn deinit(self: Self, allocator: Allocator) void {
            deinitChain(allocator, T, self.first);
        }

        pub fn put(self: *Self, node: *Node(T)) void {
            if (self.last) |last| last.next = node else self.first = node;
            self.last = node;
            node.next = null;
        }

        pub fn take(self: *Self) ?*Node(T) {
            const node = self.first orelse return null;
            self.first = node.next;
            if (node.next == null) self.last = null else node.next = null;
            return node;
        }
    };
}

test "Queue" {
    var queue = Queue(usize){};
    defer queue.deinit(test_alloc);

    try testing.expectEqual(null, queue.take());

    const n0 = try test_alloc.create(Node(usize));
    defer test_alloc.destroy(n0);
    n0.* = .{ .value = 100 };
    queue.put(n0);

    try testing.expectEqual(100, queue.take().?.value);
    try testing.expectEqual(null, queue.take());

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
    try testing.expectEqual(100, queue.take().?.value);
    try testing.expectEqual(102, queue.take().?.value);
    try testing.expectEqual(null, queue.take());

    // Assert the deinit is working:
    queue.put(try test_alloc.create(Node(usize)));
    queue.put(try test_alloc.create(Node(usize)));
}

fn Pool(comptime T: type) type {
    return struct {
        const Self = @This();

        next: ?*Node(T) = null,

        pub fn deinit(self: Self, allocator: Allocator) void {
            deinitChain(allocator, T, self.next);
        }

        pub fn retain(self: *Self, allocator: Allocator) !*Node(T) {
            const node = if (self.next) |n| blk: {
                self.next = n.next;
                break :blk n;
            } else try allocator.create(Node(T));

            node.next = null;
            return node;
        }

        pub fn release(self: *Self, node: *Node(T)) void {
            node.next = self.next;
            self.next = node;
        }
    };
}

test "Pool" {
    var pool = Pool(usize){};
    defer pool.deinit(test_alloc);

    var n0: ?*Node(usize) = try pool.retain(test_alloc);
    errdefer if (n0) |n| test_alloc.destroy(n);
    n0.?.value = 100;

    var n1: ?*Node(usize) = try pool.retain(test_alloc);
    errdefer if (n1) |n| test_alloc.destroy(n);
    n1.?.value = 101;

    pool.release(n0.?);
    n0 = null;

    n0 = try pool.retain(test_alloc);
    try testing.expectEqual(100, n0.?.value);

    var n2: ?*Node(usize) = try pool.retain(test_alloc);
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

fn Node(comptime T: type) type {
    return struct {
        value: T,
        next: ?*@This() = null,
    };
}

fn deinitChain(allocator: Allocator, comptime T: type, n: ?*Node(T)) void {
    var next = n;
    while (next) |node| {
        next = node.next;
        allocator.destroy(node);
    }
}

test "deinitChain" {
    var gpa: std.heap.GeneralPurposeAllocator(.{ .safety = true }) = .{};
    const alloc = gpa.allocator();

    var next: ?*Node(usize) = null;
    for (0..3) |i| {
        const node = try alloc.create(Node(usize));
        node.* = .{ .value = i, .next = next };
        next = node;
    }

    deinitChain(alloc, usize, next);
    try testing.expectEqual(.ok, gpa.deinit());
}
