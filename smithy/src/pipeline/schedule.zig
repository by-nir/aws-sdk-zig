const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const tsk = @import("task.zig");

pub fn TaskCallback(comptime task: tsk.Task) type {
    return if (task.Out(.retain) == void)
        *const fn (ctx: *const anyopaque) anyerror!void
    else
        *const fn (ctx: *const anyopaque, output: task.Out(.retain)) anyerror!void;
}

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

    pub fn put(self: *Schedule, comptime task: tsk.Task, input: task.In(false)) !void {
        if (task.Out(.strip) != void)
            @compileError("Task '" ++ task.name ++ "' returns a value, use `putCallback` instead.");

        const node = try self.task_pool.retain(self.allocator);
        errdefer self.task_pool.release(node);
        node.value = try PendingTask.initPrcedure(self.allocator, task, input);
        self.queue.put(node);
    }

    pub fn putCallback(
        self: *Schedule,
        comptime task: tsk.Task,
        input: task.In(false),
        context: *const anyopaque,
        callback: TaskCallback(task),
    ) !void {
        var value = try PendingTask.initCallback(self.allocator, task, input, context, callback);
        errdefer value.deinit(self.allocator);

        const node = try self.task_pool.retain(self.allocator);
        node.value = value;
        self.queue.put(node);
    }

    pub fn run(self: *Schedule) !void {
        while (self.queue.take()) |node| {
            const task = node.value;
            self.task_pool.release(node);

            const delegate = self.getDelegate();
            defer task.deinit(self.allocator);
            try task.invoke(delegate);
        }
    }

    fn getDelegate(_: *Schedule) tsk.TaskDelegate {
        return .{};
    }
};

test "Schedule: procedure" {
    var schedule = Schedule.init(test_alloc);
    defer schedule.deinit();

    try schedule.put(tsk.tests.NoOp, .{});
    try schedule.run();

    try schedule.put(tsk.tests.Failable, .{false});
    try schedule.run();

    try schedule.put(tsk.tests.Failable, .{true});
    try testing.expectError(error.Fail, schedule.run());
}

test "Schedule: callback" {
    const callback = struct {
        pub var context: usize = 0;

        pub fn call(ctx: *const anyopaque) anyerror!void {
            context = castUsize(ctx);
        }

        pub fn failable(ctx: *const anyopaque, output: error{Fail}!void) anyerror!void {
            context = castUsize(ctx);
            return output;
        }

        pub fn multiply(ctx: *const anyopaque, output: usize) anyerror!void {
            try testing.expectEqual(castUsize(ctx), output);
        }

        fn castUsize(ctx: *const anyopaque) usize {
            const cast: *const usize = @alignCast(@ptrCast(ctx));
            return cast.*;
        }
    };

    var schedule = Schedule.init(test_alloc);
    defer schedule.deinit();

    tsk.tests.did_call = false;
    try schedule.putCallback(tsk.tests.Call, .{}, &@as(usize, 100), callback.call);
    try schedule.run();
    try testing.expect(tsk.tests.did_call);
    try testing.expectEqual(100, callback.context);

    try schedule.putCallback(tsk.tests.Failable, .{false}, &@as(usize, 101), callback.failable);
    try schedule.run();
    try testing.expectEqual(101, callback.context);

    try schedule.putCallback(tsk.tests.Failable, .{true}, &@as(usize, 102), callback.failable);
    try testing.expectError(error.Fail, schedule.run());
    try testing.expectEqual(102, callback.context);

    callback.context = 108;
    try schedule.putCallback(tsk.tests.Multiply, .{ 2, 54 }, &callback.context, callback.multiply);
    try schedule.run();
}

const PendingTask = struct {
    vtable: *const Vtable,
    input: ?*const anyopaque,
    callback_ctx: ?*const anyopaque = null,
    callback_fn: ?*const anyopaque = null,

    const Vtable = struct {
        deinit: *const fn (allocator: Allocator, input: *const anyopaque) void,
        invoke: *const fn (
            delegate: tsk.TaskDelegate,
            input: ?*const anyopaque,
            ctx: ?*const anyopaque,
            cb: ?*const anyopaque,
        ) anyerror!void,
    };

    fn dupeInput(allocator: Allocator, comptime T: type, input: T) !?*const anyopaque {
        if (T == @TypeOf(.{})) return null else {
            const dupe = try allocator.create(T);
            dupe.* = input;
            return dupe;
        }
    }

    pub fn initPrcedure(allocator: Allocator, comptime task: tsk.Task, input: task.In(false)) !PendingTask {
        return PendingTask{
            .vtable = &Evaluator(task, .procedure).vtable,
            .input = try dupeInput(allocator, task.In(false), input),
        };
    }

    pub fn initCallback(
        allocator: Allocator,
        comptime task: tsk.Task,
        input: task.In(false),
        context: *const anyopaque,
        callback: TaskCallback(task),
    ) !PendingTask {
        return PendingTask{
            .vtable = &Evaluator(task, .callback).vtable,
            .input = try dupeInput(allocator, task.In(false), input),
            .callback_ctx = context,
            .callback_fn = callback,
        };
    }

    pub fn deinit(self: PendingTask, allocator: Allocator) void {
        const input = self.input orelse return;
        self.vtable.deinit(allocator, input);
    }

    pub fn invoke(self: PendingTask, delegate: tsk.TaskDelegate) !void {
        try self.vtable.invoke(delegate, self.input, self.callback_ctx, self.callback_fn);
    }

    const Invocaction = enum { procedure, callback };

    fn Evaluator(comptime task: tsk.Task, comptime invocation: Invocaction) type {
        return struct {
            pub const vtable = Vtable{
                .deinit = deinitInput,
                .invoke = invokeTask,
            };

            fn deinitInput(alloc: Allocator, in: *const anyopaque) void {
                std.debug.assert(task.input != null);
                const inpt: *const task.In(false) = @alignCast(@ptrCast(in));
                alloc.destroy(inpt);
            }

            fn invokeTask(
                delegate: tsk.TaskDelegate,
                in: ?*const anyopaque,
                ctx: ?*const anyopaque,
                callback: ?*const anyopaque,
            ) anyerror!void {
                const out = if (task.input == null) task.invoke(delegate, .{}) else blk: {
                    const inpt: *const task.In(false) = @alignCast(@ptrCast(in.?));
                    break :blk task.invoke(delegate, inpt.*);
                };

                switch (invocation) {
                    Invocaction.procedure => return out,
                    Invocaction.callback => {
                        const cb: TaskCallback(task) = @alignCast(@ptrCast(callback.?));
                        if (task.Out(.retain) == void) try cb(ctx.?) else try cb(ctx.?, out);
                    },
                }
            }
        };
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
