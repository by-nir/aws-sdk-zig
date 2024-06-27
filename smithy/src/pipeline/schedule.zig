const std = @import("std");
const Instant = std.time.Instant;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const tsk = @import("task.zig");
const util = @import("utils.zig");
const ComptimeTag = util.ComptimeTag;

pub const InvokeMethod = enum { sync, asyncd, callback };

pub const Schedule = struct {
    allocator: Allocator,
    queue: util.Queue(AsyncInvocation) = .{},
    task_pool: util.Pool(AsyncInvocation) = .{
        .clearValue = clearNode,
    },
    tracer: ScheduleTracer = NoOpTracer.any,

    pub fn init(allocator: Allocator) Schedule {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: Schedule) void {
        self.queue.deinit(self.allocator, true);
        self.task_pool.deinit(self.allocator, true);
    }

    pub fn invokeSync(self: *Schedule, comptime task: tsk.Task, input: task.In(false)) task.Out(.retain) {
        const delegate = self.getDelegate();
        const sample = self.tracer.begin();
        defer sample.didInvoke(.sync, ComptimeTag.of(task));
        return task.invoke(delegate, input);
    }

    pub fn invokeAsync(self: *Schedule, comptime task: tsk.Task, input: task.In(false)) !void {
        if (task.Out(.strip) != void)
            @compileError("Task '" ++ task.name ++ "' returns a value, use `putCallback` instead.");

        const node = try self.task_pool.retain(self.allocator);
        errdefer self.task_pool.release(node);
        node.value = try AsyncInvocation.init(self.allocator, task, input);
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
        node.value = try AsyncInvocation.initCallback(self.allocator, task, input, context, callback);
        self.queue.put(node);
    }

    pub fn run(self: *Schedule) !void {
        while (self.queue.take()) |node| {
            const task = node.value;
            self.task_pool.release(node);

            const delegate = self.getDelegate();
            defer task.deinit(self.allocator);
            try task.invoke(self.tracer, delegate);
        }
    }

    fn getDelegate(self: *Schedule) tsk.TaskDelegate {
        return .{ .scheduler = self };
    }

    fn clearNode(node: *util.ChainNode(AsyncInvocation)) void {
        node.value = AsyncInvocation.empty;
    }
};

const AsyncInvocation = struct {
    vtable: *allowzero const VTable,
    input: ?*const anyopaque,
    callback_ctx: ?*const anyopaque = null,
    callback_fn: ?*const anyopaque = null,

    pub const empty = AsyncInvocation{
        .vtable = @ptrFromInt(0),
        .input = null,
    };

    const VTable = struct {
        deinit: *const fn (allocator: Allocator, input: *const anyopaque) void,
        invoke: *const fn (
            tracer: ScheduleTracer,
            delegate: tsk.TaskDelegate,
            input: ?*const anyopaque,
            ctx: ?*const anyopaque,
            cb: ?*const anyopaque,
        ) anyerror!void,
    };

    pub fn init(allocator: Allocator, comptime task: tsk.Task, input: task.In(false)) !AsyncInvocation {
        const K = Invoker(task, .asyncd);
        return AsyncInvocation{
            .vtable = &K.async_vtable,
            .input = try K.allocAsyncInput(allocator, input),
        };
    }

    pub fn initCallback(
        allocator: Allocator,
        comptime task: tsk.Task,
        input: task.In(false),
        context: *const anyopaque,
        callback: tsk.TaskCallback(task),
    ) !AsyncInvocation {
        const K = Invoker(task, .callback);
        return AsyncInvocation{
            .vtable = &K.async_vtable,
            .input = try K.allocAsyncInput(allocator, input),
            .callback_ctx = context,
            .callback_fn = callback,
        };
    }

    pub fn deinit(self: AsyncInvocation, allocator: Allocator) void {
        if (self.input) |in| self.vtable.deinit(allocator, in);
    }

    pub fn invoke(self: AsyncInvocation, tracer: ScheduleTracer, delegate: tsk.TaskDelegate) !void {
        try self.vtable.invoke(tracer, delegate, self.input, self.callback_ctx, self.callback_fn);
    }
};

fn Invoker(comptime task: tsk.Task, comptime method: InvokeMethod) type {
    return struct {
        pub const async_vtable = AsyncInvocation.VTable{
            .deinit = deallocAsyncInput,
            .invoke = invokeAsyncTask,
        };

        pub fn allocAsyncInput(allocator: Allocator, input: task.In(false)) !?*const anyopaque {
            if (task.input == null) return null else {
                const dupe = try allocator.create(task.In(false));
                dupe.* = input;
                return dupe;
            }
        }

        fn deallocAsyncInput(alloc: Allocator, in: *const anyopaque) void {
            std.debug.assert(task.input != null);
            const input: *const task.In(false) = @alignCast(@ptrCast(in));
            alloc.destroy(input);
        }

        fn invokeAsyncTask(
            tracer: ScheduleTracer,
            delegate: tsk.TaskDelegate,
            in: ?*const anyopaque,
            ctx: ?*const anyopaque,
            callback: ?*const anyopaque,
        ) anyerror!void {
            const out = blk: {
                const sample = tracer.begin();
                defer sample.didInvoke(method, ComptimeTag.of(task));
                if (task.input == null) {
                    break :blk task.invoke(delegate, .{});
                } else {
                    const inpt: *const task.In(false) = @alignCast(@ptrCast(in.?));
                    break :blk task.invoke(delegate, inpt.*);
                }
            };

            switch (method) {
                .sync => unreachable,
                .asyncd => return out,
                .callback => {
                    const sample = tracer.begin();
                    defer sample.didCallback(ComptimeTag.of(callback.?), ctx.?);
                    const cb: tsk.TaskCallback(task) = @alignCast(@ptrCast(callback.?));
                    if (task.Out(.retain) == void) try cb(ctx.?) else try cb(ctx.?, out);
                },
            }
        }
    };
}

pub const ScheduleTracer = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        didInvoke: *const fn (ctx: *anyopaque, method: InvokeMethod, task: ComptimeTag, elapsed_ns: u64) void,
        didCallback: *const fn (ctx: *anyopaque, callback: ComptimeTag, context: *const anyopaque, elapsed_ns: u64) void,
    };

    pub fn begin(self: ScheduleTracer) Sample {
        return .{
            .ctx = self.ctx,
            .vtable = self.vtable,
            .start = Instant.now() catch unreachable,
        };
    }

    pub const Sample = struct {
        ctx: *anyopaque,
        vtable: *const VTable,
        start: Instant,

        pub fn didInvoke(self: Sample, method: InvokeMethod, task: ComptimeTag) void {
            const elapsed_ns = self.sample().since(self.start);
            self.vtable.didInvoke(self.ctx, method, task, elapsed_ns);
        }

        pub fn didCallback(self: Sample, callback: ComptimeTag, context: *const anyopaque) void {
            const elapsed_ns = self.sample().since(self.start);
            self.vtable.didCallback(self.ctx, callback, context, elapsed_ns);
        }

        fn sample(self: Sample) Instant {
            const current = Instant.now() catch unreachable;
            return if (current.order(self.start) == .gt) current else self.start;
        }
    };
};

const NoOpTracer = struct {
    pub const any = ScheduleTracer{
        .ctx = undefined,
        .vtable = &vtable,
    };

    const vtable = ScheduleTracer.VTable{
        .didInvoke = didInvoke,
        .didCallback = didCallback,
    };

    fn didInvoke(_: *anyopaque, _: InvokeMethod, _: ComptimeTag, _: u64) void {}

    fn didCallback(_: *anyopaque, _: ComptimeTag, _: *const anyopaque, _: u64) void {}
};

pub const ScheduleTester = struct {
    schedule: Schedule,
    invoke_records: std.ArrayListUnmanaged(InvokeRecord) = .{},
    callback_records: std.ArrayListUnmanaged(CallbackRecord) = .{},

    const InvokeRecord = struct { method: InvokeMethod, task: ComptimeTag };
    const CallbackRecord = struct { callback: ComptimeTag, context: *const anyopaque };

    pub fn init() !*ScheduleTester {
        const tester = try test_alloc.create(ScheduleTester);
        tester.* = .{ .schedule = Schedule.init(test_alloc) };
        tester.schedule.tracer = .{ .ctx = tester, .vtable = &tracer };
        return tester;
    }

    pub fn deinit(self: *ScheduleTester) void {
        self.schedule.deinit();
        self.invoke_records.deinit(test_alloc);
        self.callback_records.deinit(test_alloc);
        test_alloc.destroy(self);
    }

    pub fn clear(self: *ScheduleTester) void {
        self.invoke_records.clearRetainingCapacity();
        self.callback_records.clearRetainingCapacity();
    }

    pub fn invokeSync(self: *ScheduleTester, comptime task: tsk.Task, input: task.In(false)) task.Out(.retain) {
        return self.schedule.invokeSync(task, input);
    }

    pub fn invokeAsync(self: *ScheduleTester, comptime task: tsk.Task, input: task.In(false)) !void {
        try self.schedule.invokeAsync(task, input);
    }

    pub fn invokeCallback(
        self: *ScheduleTester,
        comptime task: tsk.Task,
        input: task.In(false),
        context: *const anyopaque,
        callback: tsk.TaskCallback(task),
    ) !void {
        try self.schedule.invokeCallback(task, input, context, callback);
    }

    pub fn run(self: *ScheduleTester) !void {
        try self.schedule.run();
    }

    const tracer = ScheduleTracer.VTable{
        .didInvoke = didInvoke,
        .didCallback = didCallback,
    };

    fn didInvoke(ctx: *anyopaque, method: InvokeMethod, task: ComptimeTag, _: u64) void {
        const self = selfCtx(ctx);
        const record = .{ .method = method, .task = task };
        self.invoke_records.append(test_alloc, record) catch unreachable;
    }

    fn didCallback(ctx: *anyopaque, callback: ComptimeTag, context: *const anyopaque, _: u64) void {
        const self = selfCtx(ctx);
        const record = .{ .callback = callback, .context = context };
        self.callback_records.append(test_alloc, record) catch unreachable;
    }

    fn selfCtx(ctx: *anyopaque) *ScheduleTester {
        return @alignCast(@ptrCast(ctx));
    }

    pub fn expectInvoke(
        self: ScheduleTester,
        order: usize,
        method: InvokeMethod,
        comptime task: tsk.Task,
    ) !void {
        if (self.invoke_records.items.len <= order) return error.OrderOutOfBounds;
        const record = self.invoke_records.items[order];
        try testing.expectEqual(method, record.method);
        try testing.expectEqual(ComptimeTag.of(task), record.task);
    }

    pub fn expectCallback(
        self: ScheduleTester,
        order: usize,
        callback: *const anyopaque,
        context: ?*const anyopaque,
    ) !void {
        if (self.callback_records.items.len <= order) return error.OrderOutOfBounds;
        const record = self.callback_records.items[order];
        try testing.expectEqual(ComptimeTag.of(callback), record.callback);
        if (context) |expected| try testing.expectEqual(expected, record.context);
    }
};

test "invoke sync" {
    var tester = try ScheduleTester.init();
    defer tester.deinit();

    tester.invokeSync(tsk.tests.Call, .{});
    try tester.invokeSync(tsk.tests.Failable, .{false});
    const fail = tester.invokeSync(tsk.tests.Failable, .{true});
    try testing.expectError(error.Fail, fail);

    try tester.expectInvoke(0, .sync, tsk.tests.Call);
    try tester.expectInvoke(1, .sync, tsk.tests.Failable);
    try tester.expectInvoke(2, .sync, tsk.tests.Failable);
}

test "invoke async" {
    var tester = try ScheduleTester.init();
    defer tester.deinit();

    try tester.invokeAsync(tsk.tests.Call, .{});
    try tester.invokeAsync(tsk.tests.Failable, .{false});
    try tester.invokeAsync(tsk.tests.Failable, .{true});
    try testing.expectError(error.Fail, tester.run());

    try tester.expectInvoke(0, .asyncd, tsk.tests.Call);
    try tester.expectInvoke(1, .asyncd, tsk.tests.Failable);
    try tester.expectInvoke(2, .asyncd, tsk.tests.Failable);
}

test "invoke callback" {
    var tester = try ScheduleTester.init();
    defer tester.deinit();

    try tester.invokeCallback(tsk.tests.Multiply, .{ 2, 54 }, &@as(usize, 108), test_callback.multiply);
    try tester.invokeCallback(tsk.tests.Call, .{}, &@as(usize, 101), test_callback.noop);
    try tester.invokeCallback(tsk.tests.Failable, .{false}, &@as(usize, 102), test_callback.failable);
    try tester.invokeCallback(tsk.tests.Failable, .{true}, &@as(usize, 103), test_callback.failable);
    try testing.expectError(error.Fail, tester.run());

    try tester.expectInvoke(0, .callback, tsk.tests.Multiply);
    try tester.expectCallback(0, test_callback.multiply, &@as(usize, 108));
    try tester.expectInvoke(1, .callback, tsk.tests.Call);
    try tester.expectCallback(1, test_callback.noop, &@as(usize, 101));
    try tester.expectInvoke(2, .callback, tsk.tests.Failable);
    try tester.expectCallback(2, test_callback.failable, &@as(usize, 102));
    try tester.expectInvoke(3, .callback, tsk.tests.Failable);
    try tester.expectCallback(3, test_callback.failable, &@as(usize, 103));
}

test "schedule sub-tasks" {
    var schedule = Schedule.init(test_alloc);
    defer schedule.deinit();

    const tasks = struct {
        pub const Root = tsk.Task.define("Root", root, .{});
        pub fn root(task: tsk.TaskDelegate) anyerror!void {
            try task.invokeAsync(Bar, .{});
            task.invokeSync(Foo, .{});
            try task.invokeCallback(Baz, .{}, undefined, test_callback.noop);
        }

        pub const Foo = tsk.Task.define("Foo", tsk.tests.noOp, .{});
        pub const Bar = tsk.Task.define("Bar", tsk.tests.noOp, .{});
        pub const Baz = tsk.Task.define("Baz", tsk.tests.noOp, .{});
    };

    var tester = try ScheduleTester.init();
    defer tester.deinit();

    try tester.invokeAsync(tasks.Root, .{});
    try tester.run();

    try tester.expectInvoke(0, .sync, tasks.Foo);
    try tester.expectInvoke(1, .asyncd, tasks.Root);
    try tester.expectInvoke(2, .asyncd, tasks.Bar);
    try tester.expectInvoke(3, .callback, tasks.Baz);
}

const test_callback = struct {
    pub fn noop(_: *const anyopaque) anyerror!void {}

    pub fn failable(_: *const anyopaque, output: error{Fail}!void) anyerror!void {
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
