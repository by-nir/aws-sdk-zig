const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const tsk = @import("task.zig");
const util = @import("utils.zig");

pub const Schedule = struct {
    allocator: Allocator,
    queue: util.Queue(PendingTask) = .{},
    task_pool: util.Pool(PendingTask) = .{
        .clearValue = clearNode,
    },

    pub fn init(allocator: Allocator) Schedule {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: Schedule) void {
        self.queue.deinit(self.allocator, true);
        self.task_pool.deinit(self.allocator, true);
    }

    pub fn invokeSync(self: *Schedule, comptime task: tsk.Task, input: task.In(false)) task.Out(.retain) {
        const delegate = self.getDelegate();
        return task.invoke(delegate, input);
    }

    pub fn invokeAsync(self: *Schedule, comptime task: tsk.Task, input: task.In(false)) !void {
        if (task.Out(.strip) != void)
            @compileError("Task '" ++ task.name ++ "' returns a value, use `putCallback` instead.");

        const node = try self.task_pool.retain(self.allocator);
        errdefer self.task_pool.release(node);
        node.value = try PendingTask.initPrcedure(self.allocator, task, input);
        self.queue.put(node);
    }

    pub fn invokeCallback(
        self: *Schedule,
        comptime task: tsk.Task,
        input: task.In(false),
        context: *const anyopaque,
        callback: tsk.TaskCallback(task),
    ) !void {
        const node = try self.task_pool.retain(self.allocator);
        errdefer self.task_pool.release(node);
        node.value = try PendingTask.initCallback(self.allocator, task, input, context, callback);
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

    fn getDelegate(self: *Schedule) tsk.TaskDelegate {
        return .{ .scheduler = self };
    }

    fn clearNode(node: *util.ChainNode(PendingTask)) void {
        node.value = PendingTask.empty;
    }
};

const PendingTask = struct {
    vtable: *allowzero const Vtable,
    input: ?*const anyopaque,
    callback_ctx: ?*const anyopaque = null,
    callback_fn: ?*const anyopaque = null,

    pub const empty = PendingTask{
        .vtable = @ptrFromInt(0),
        .input = null,
    };

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
        callback: tsk.TaskCallback(task),
    ) !PendingTask {
        return PendingTask{
            .vtable = &Evaluator(task, .callback).vtable,
            .input = try dupeInput(allocator, task.In(false), input),
            .callback_ctx = context,
            .callback_fn = callback,
        };
    }

    pub fn deinit(self: PendingTask, allocator: Allocator) void {
        if (self.input) |in| self.vtable.deinit(allocator, in);
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
                        const cb: tsk.TaskCallback(task) = @alignCast(@ptrCast(callback.?));
                        if (task.Out(.retain) == void) try cb(ctx.?) else try cb(ctx.?, out);
                    },
                }
            }
        };
    }
};

test "Schedule: procedures" {
    var schedule = Schedule.init(test_alloc);
    defer schedule.deinit();

    try schedule.invokeAsync(tsk.tests.NoOp, .{});
    try schedule.run();

    try schedule.invokeAsync(tsk.tests.Failable, .{false});
    try schedule.run();

    try schedule.invokeAsync(tsk.tests.Failable, .{true});
    try testing.expectError(error.Fail, schedule.run());
}

test "Schedule: callbacks" {
    var schedule = Schedule.init(test_alloc);
    defer schedule.deinit();

    tests.context = 0;
    tsk.tests.did_call = false;
    try schedule.invokeCallback(tsk.tests.Call, .{}, &@as(usize, 101), tests.call);
    try schedule.run();
    try testing.expect(tsk.tests.did_call);
    try testing.expectEqual(101, tests.context);

    try schedule.invokeCallback(tsk.tests.Failable, .{false}, &@as(usize, 102), tests.failable);
    try schedule.run();
    try testing.expectEqual(102, tests.context);

    try schedule.invokeCallback(tsk.tests.Failable, .{true}, &@as(usize, 103), tests.failable);
    try testing.expectError(error.Fail, schedule.run());
    try testing.expectEqual(103, tests.context);

    tests.context = 108;
    try schedule.invokeCallback(tsk.tests.Multiply, .{ 2, 54 }, &tests.context, tests.multiply);
    try schedule.run();
}

const tests = struct {
    pub var context: usize = 0;

    pub fn call(ctx: *const anyopaque) anyerror!void {
        context = castUsize(ctx);
    }

    pub fn failable(ctx: *const anyopaque, output: error{Fail}!void) anyerror!void {
        context = castUsize(ctx);
        try output;
    }

    pub fn multiply(ctx: *const anyopaque, output: usize) anyerror!void {
        try testing.expectEqual(castUsize(ctx), output);
    }

    fn castUsize(ctx: *const anyopaque) usize {
        const cast: *const usize = @alignCast(@ptrCast(ctx));
        return cast.*;
    }
};
