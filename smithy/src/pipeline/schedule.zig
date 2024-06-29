const std = @import("std");
const Instant = std.time.Instant;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const tsk = @import("task.zig");
const scp = @import("scope.zig");
const util = @import("utils.zig");
const ComptimeTag = util.ComptimeTag;
const Node = util.Node;

pub const ScheduleNode = Node(Invocation);

pub const Schedule = struct {
    allocator: Allocator,
    invocation_queue: util.Queue(Invocation) = .{},
    invocation_pool: util.Pool(Node(Invocation)) = .{
        .createItem = createInvocation,
        .destroyItem = destroyInvocation,
        .resetItem = resetInvocation,
    },
    tracer: ScheduleTracer = NoOpTracer.any,

    pub fn init(allocator: Allocator) Schedule {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Schedule) void {
        self.invocation_queue.deinit(self.allocator, true);
        self.invocation_pool.deinit(self.allocator);
    }

    pub fn invokeSync(self: *Schedule, comptime task: tsk.Task, input: task.In(false)) !task.Out(.strip) {
        var root = ScheduleNode{ .value = .invalid };
        errdefer self.releaseQueue(&root.children);

        const output = blk: {
            const sample = self.tracer.begin();
            defer sample.didInvoke(.sync, ComptimeTag.of(task));
            break :blk task.invoke(self.getDelegate(&root), input);
        };
        if (task.Out(.strip) != task.Out(.retain)) try output;

        if (root.children.first != null) try self.evaluateQueue(&root.children);
        return output;
    }

    pub fn invokeAsync(
        self: *Schedule,
        parent: ?*ScheduleNode,
        comptime task: tsk.Task,
        input: task.In(false),
    ) !void {
        if (task.Out(.strip) != void)
            @compileError("Task '" ++ task.name ++ "' returns a value, use `putCallback` instead.");

        const node = try self.invocation_pool.retain(self.allocator);
        errdefer self.invocation_pool.release(self.allocator, node);
        node.value = try Invocation.initAsync(self.allocator, task, input);

        const queue = if (parent) |p| &p.children else &self.invocation_queue;
        queue.put(node);
    }

    pub fn invokeCallback(
        self: *Schedule,
        parent: ?*ScheduleNode,
        comptime task: tsk.Task,
        input: task.In(false),
        context: *const anyopaque,
        callback: tsk.TaskCallback(task),
    ) !void {
        const node = try self.invocation_pool.retain(self.allocator);
        errdefer self.invocation_pool.release(self.allocator, node);
        node.value = try Invocation.initCallback(self.allocator, task, input, context, callback);

        const queue = if (parent) |p| &p.children else &self.invocation_queue;
        queue.put(node);
    }

    pub fn run(self: *Schedule) !void {
        return self.evaluateQueue(&self.invocation_queue);
    }

    fn evaluateQueue(self: *Schedule, queue: *util.Queue(Invocation)) !void {
        var next: ?*ScheduleNode = queue.peek();
        while (next) |node| : (next = queue.peek()) {
            const invocation = node.value;
            defer {
                queue.dropNext();
                invocation.cleanup(self.allocator);
                self.invocation_pool.release(self.allocator, node);
            }
            errdefer self.releaseQueue(&node.children);

            try invocation.evaluate(self.tracer, self.getDelegate(node));
            try self.evaluateQueue(&node.children);
        }
    }

    fn getDelegate(self: *Schedule, node: *ScheduleNode) tsk.TaskDelegate {
        return .{
            .node = node,
            .scheduler = self,
        };
    }

    fn createInvocation(allocator: Allocator) !*ScheduleNode {
        return Node(Invocation).init(allocator, .invalid);
    }

    fn destroyInvocation(allocator: Allocator, node: *ScheduleNode) void {
        allocator.destroy(node);
    }

    fn resetInvocation(node: *ScheduleNode) void {
        node.value = .invalid;
    }
};

const Invocation = union(enum) {
    invalid,
    scope: *scp.Scope,
    task_async: Async,
    task_callback: Callback,

    pub const Async = struct {
        vtable: *const VTable,
        input: ?*const anyopaque,

        const VTable = struct {
            deinit: ?*const fn (allocator: Allocator, input: *const anyopaque) void,
            invoke: *const fn (
                tracer: ScheduleTracer,
                delegate: tsk.TaskDelegate,
                input: ?*const anyopaque,
            ) anyerror!void,
        };
    };

    pub const Callback = struct {
        vtable: *const VTable,
        input: ?*const anyopaque,
        context: *const anyopaque,
        callback: *const anyopaque,

        const VTable = struct {
            deinit: ?*const fn (allocator: Allocator, input: *const anyopaque) void,
            invoke: *const fn (
                tracer: ScheduleTracer,
                delegate: tsk.TaskDelegate,
                input: ?*const anyopaque,
                ctx: *const anyopaque,
                cb: *const anyopaque,
            ) anyerror!void,
        };
    };

    pub fn initAsync(allocator: Allocator, comptime task: tsk.Task, input: task.In(false)) !Invocation {
        return .{ .task_async = .{
            .vtable = &AsyncInvoker(task, .asyncd).vtable,
            .input = try AsyncInput(task.In(false)).allocate(allocator, input),
        } };
    }

    pub fn initCallback(
        allocator: Allocator,
        comptime task: tsk.Task,
        input: task.In(false),
        context: *const anyopaque,
        callback: tsk.TaskCallback(task),
    ) !Invocation {
        return .{ .task_callback = .{
            .vtable = &AsyncInvoker(task, .callback).vtable,
            .input = try AsyncInput(task.In(false)).allocate(allocator, input),
            .context = context,
            .callback = callback,
        } };
    }

    pub fn deinit(self: Invocation, allocator: Allocator) void {
        switch (self) {
            .invalid => {},
            .scope => |t| t.deinit(),
            inline .task_async, .task_callback => |t| {
                if (t.input) |in| t.vtable.deinit.?(allocator, in);
            },
        }
    }

    pub fn evaluate(self: Invocation, tracer: ScheduleTracer, delegate: tsk.TaskDelegate) !void {
        switch (self) {
            .scope => {},
            .task_async => |t| try t.vtable.invoke(tracer, delegate, t.input),
            .task_callback => |t| try t.vtable.invoke(tracer, delegate, t.input, t.context, t.callback),
            else => unreachable,
        }
    }

    pub fn cleanup(self: Invocation, allocator: Allocator) void {
        switch (self) {
            .scope => |t| t.reset(),
            inline .task_async, .task_callback => |t| {
                if (t.input) |in| t.vtable.deinit.?(allocator, in);
            },
            else => unreachable,
        }
    }
};

pub const InvokeMethod = enum { sync, asyncd, callback };

fn AsyncInvoker(comptime task: tsk.Task, comptime method: InvokeMethod) type {
    const deinitFn = if (task.input != null) &AsyncInput(task.In(false)).deallocate else null;
    return struct {
        pub const vtable = switch (method) {
            .sync => unreachable,
            .asyncd => Invocation.Async.VTable{ .deinit = deinitFn, .invoke = invokeAsync },
            .callback => Invocation.Callback.VTable{ .deinit = deinitFn, .invoke = invokeCallback },
        };

        fn invokeAsync(tracer: ScheduleTracer, delegate: tsk.TaskDelegate, in: ?*const anyopaque) anyerror!void {
            return invokeTask(tracer, delegate, in);
        }

        fn invokeTask(tracer: ScheduleTracer, delegate: tsk.TaskDelegate, in: ?*const anyopaque) task.Out(.retain) {
            const sample = tracer.begin();
            defer sample.didInvoke(method, ComptimeTag.of(task));

            if (task.input == null) {
                return task.invoke(delegate, .{});
            } else {
                const inpt: *const task.In(false) = @alignCast(@ptrCast(in.?));
                return task.invoke(delegate, inpt.*);
            }
        }

        fn invokeCallback(
            tracer: ScheduleTracer,
            delegate: tsk.TaskDelegate,
            in: ?*const anyopaque,
            ctx: *const anyopaque,
            callback: *const anyopaque,
        ) anyerror!void {
            // If the inocation fails we pass the error to the callback to handle it (or return it).
            const out = invokeTask(tracer, delegate, in);

            const sample = tracer.begin();
            defer sample.didCallback(ComptimeTag.of(callback), ctx);
            const cb: tsk.TaskCallback(task) = @alignCast(@ptrCast(callback));
            if (task.Out(.retain) == void) try cb(ctx) else try cb(ctx, out);
        }
    };
}

fn AsyncInput(comptime T: type) type {
    return struct {
        pub fn allocate(allocator: Allocator, input: T) !?*const anyopaque {
            if (T == @TypeOf(.{})) return null else {
                const dupe = try allocator.create(T);
                dupe.* = input;
                return dupe;
            }
        }

        pub fn deallocate(alloc: Allocator, in: *const anyopaque) void {
            if (T == @TypeOf(.{})) @compileError("Unexpected call to deallocate on void input.");

            const input: *const T = @alignCast(@ptrCast(in));
            alloc.destroy(input);
        }
    };
}

pub const ScheduleTracer = struct {
    ctx: *allowzero anyopaque,
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
        .ctx = @ptrFromInt(0),
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

    const tracer = ScheduleTracer.VTable{
        .didInvoke = didInvoke,
        .didCallback = didCallback,
    };

    fn didInvoke(ctx: *anyopaque, method: InvokeMethod, task: ComptimeTag, _: u64) void {
        const self: *ScheduleTester = @alignCast(@ptrCast(ctx));
        const record = .{ .method = method, .task = task };
        self.invoke_records.append(test_alloc, record) catch unreachable;
    }

    fn didCallback(ctx: *anyopaque, callback: ComptimeTag, context: *const anyopaque, _: u64) void {
        const self: *ScheduleTester = @alignCast(@ptrCast(ctx));
        const record = .{ .callback = callback, .context = context };
        self.callback_records.append(test_alloc, record) catch unreachable;
    }

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

    pub fn invokeSync(self: *ScheduleTester, comptime task: tsk.Task, input: task.In(false)) !task.Out(.strip) {
        return self.schedule.invokeSync(task, input);
    }

    pub inline fn invokeSyncExpectError(
        self: *ScheduleTester,
        expected: anyerror,
        comptime task: tsk.Task,
        input: task.In(false),
    ) !void {
        const output = self.schedule.invokeSync(task, input);
        try testing.expectError(expected, output);
    }

    pub fn invokeAsync(self: *ScheduleTester, comptime task: tsk.Task, input: task.In(false)) !void {
        try self.schedule.invokeAsync(null, task, input);
    }

    pub fn invokeCallback(
        self: *ScheduleTester,
        comptime task: tsk.Task,
        input: task.In(false),
        context: *const anyopaque,
        callback: tsk.TaskCallback(task),
    ) !void {
        try self.schedule.invokeCallback(null, task, input, context, callback);
    }

    pub fn run(self: *ScheduleTester) !void {
        try self.schedule.run();
    }

    pub inline fn runExpectError(self: *ScheduleTester, expected: anyerror) !void {
        try testing.expectError(expected, self.schedule.run());
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

    try tester.invokeSync(tsk.tests.Call, .{});
    try tester.invokeSync(tsk.tests.Failable, .{false});
    try tester.invokeSyncExpectError(error.Fail, tsk.tests.Failable, .{true});

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
    try tester.runExpectError(error.Fail);

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
    try tester.runExpectError(error.Fail);

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
            try task.invokeSync(Foo, .{});
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
