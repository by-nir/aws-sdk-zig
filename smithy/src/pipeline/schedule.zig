const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const tsk = @import("task.zig");
const Task = tsk.Task;
const scp = @import("scope.zig");
const Scope = scp.Scope;
const Delegate = scp.Delegate;
const util = @import("utils.zig");
const ComptimeTag = util.ComptimeTag;

const ScheduleNode = util.Node(Invocation);
pub const ScheduleQueue = util.Queue(Invocation);
const InvokeMethod = enum { sync, asyncd, callback };

pub const Schedule = struct {
    allocator: Allocator,
    resources: *ScheduleResources,
    root_scope: *Scope,
    queue: ScheduleQueue = .{},
    tracer: ScheduleTracer = NoOpTracer.any,

    pub fn init(allocator: Allocator, resources: *ScheduleResources, scope: *Scope) Schedule {
        return .{
            .allocator = allocator,
            .resources = resources,
            .root_scope = scope,
        };
    }

    pub fn deinit(self: *Schedule) void {
        self.resources.releaseQueue(&self.queue);
    }

    pub fn invokeSync(
        self: *Schedule,
        parent: ?*const Delegate,
        comptime task: Task,
        input: task.In(false),
    ) !task.Out(.strip) {
        var delegate = self.delegateFor(if (parent) |p| p.scope else self.root_scope);
        defer if (delegate.branchScope == null) self.resources.releaseScope(delegate.scope);
        errdefer self.resources.releaseQueue(&delegate.children);

        const output = blk: {
            const sample = self.tracer.begin();
            defer sample.didInvoke(.sync, ComptimeTag.of(task));
            break :blk task.invoke(&delegate, input);
        };
        if (task.Out(.strip) != task.Out(.retain)) try output;

        try self.evaluateQueue(delegate.scope, &delegate.children);
        return output;
    }

    pub fn appendAsync(self: *Schedule, parent: ?*const Delegate, comptime task: Task, input: task.In(false)) !void {
        if (task.Out(.strip) != void)
            @compileError("Task '" ++ task.name ++ "' returns a value, use `appendAsync` instead.");

        const node = try self.resources.retainInvocation();
        errdefer self.resources.releaseInvocation(node);
        node.value = try Invocation.initAsync(self.allocator, task, input);

        const queue = if (parent) |p| @constCast(&p.children) else &self.queue;
        queue.put(node);
    }

    pub fn appendCallback(
        self: *Schedule,
        parent: ?*const Delegate,
        comptime task: Task,
        input: task.In(false),
        context: *const anyopaque,
        callback: Task.Callback(task),
    ) !void {
        const node = try self.resources.retainInvocation();
        errdefer self.resources.releaseInvocation(node);
        node.value = try Invocation.initCallback(self.allocator, task, input, context, callback);

        const queue = if (parent) |p| @constCast(&p.children) else &self.queue;
        queue.put(node);
    }

    pub fn evaluate(self: *Schedule) !void {
        return self.evaluateQueue(self.root_scope, &self.queue);
    }

    fn evaluateQueue(self: *Schedule, scope: *Scope, queue: *ScheduleQueue) !void {
        var next: ?*ScheduleNode = queue.peek();
        while (next) |node| : (next = queue.peek()) {
            const invocation = node.value;
            defer {
                queue.dropNext();
                invocation.cleanup(self.allocator);
                self.resources.releaseInvocation(node);
            }
            errdefer self.resources.releaseQueue(&node.children);

            var delegate = self.delegateFor(scope);
            defer if (delegate.branchScope == null) self.resources.releaseScope(delegate.scope);

            try invocation.evaluate(self.tracer, &delegate);
            try self.evaluateQueue(delegate.scope, &delegate.children);
        }
    }

    fn delegateFor(self: *Schedule, scope: *Scope) Delegate {
        return .{
            .scope = scope,
            .scheduler = self,
            .children = .{},
            .branchScope = branchScope,
        };
    }

    fn branchScope(delegate: *const Delegate) !void {
        const child = try delegate.scheduler.resources.retainScope();
        child.parent = delegate.scope;

        const mutable: *Delegate = @constCast(delegate);
        mutable.scope = child;
        mutable.branchScope = null;
    }
};

const Invocation = union(enum) {
    invalid,
    task_async: Async,
    task_callback: Callback,

    pub const Async = struct {
        vtable: *const VTable,
        input: ?*const anyopaque,

        const VTable = struct {
            deinit: ?*const fn (allocator: Allocator, input: *const anyopaque) void,
            invoke: *const fn (
                tracer: ScheduleTracer,
                delegate: *const Delegate,
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
                delegate: *const Delegate,
                input: ?*const anyopaque,
                ctx: *const anyopaque,
                cb: *const anyopaque,
            ) anyerror!void,
        };
    };

    pub fn initAsync(allocator: Allocator, comptime task: Task, input: task.In(false)) !Invocation {
        return .{ .task_async = .{
            .vtable = &AsyncInvoker(task, .asyncd).vtable,
            .input = try AsyncInput(task.In(false)).allocate(allocator, input),
        } };
    }

    pub fn initCallback(
        allocator: Allocator,
        comptime task: Task,
        input: task.In(false),
        context: *const anyopaque,
        callback: Task.Callback(task),
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
            inline .task_async, .task_callback => |t| {
                if (t.input) |in| t.vtable.deinit.?(allocator, in);
            },
            .invalid => {},
        }
    }

    pub fn evaluate(self: Invocation, tracer: ScheduleTracer, delegate: *const Delegate) !void {
        switch (self) {
            .task_async => |t| try t.vtable.invoke(tracer, delegate, t.input),
            .task_callback => |t| try t.vtable.invoke(tracer, delegate, t.input, t.context, t.callback),
            .invalid => unreachable,
        }
    }

    pub fn cleanup(self: Invocation, allocator: Allocator) void {
        switch (self) {
            inline .task_async, .task_callback => |t| {
                if (t.input) |in| t.vtable.deinit.?(allocator, in);
            },
            .invalid => unreachable,
        }
    }
};

fn AsyncInput(comptime T: type) type {
    return struct {
        pub fn allocate(allocator: Allocator, input: T) !?*const anyopaque {
            if (T == @TypeOf(.{})) return null else {
                const dupe = try allocator.create(T);
                dupe.* = input;
                return dupe;
            }
        }

        pub fn deallocate(alloc: Allocator, input: *const anyopaque) void {
            if (T == @TypeOf(.{})) @compileError("Unexpected call to deallocate on void input.");
            alloc.destroy(cast(input));
        }

        pub fn cast(input: *const anyopaque) *const T {
            return @alignCast(@ptrCast(input));
        }
    };
}

test "AsyncInput" {
    const T = struct { usize };
    const input = try AsyncInput(T).allocate(test_alloc, T{108});
    defer AsyncInput(T).deallocate(test_alloc, input.?);
    try testing.expectEqualDeep(&T{108}, AsyncInput(T).cast(input.?));
}

fn AsyncInvoker(comptime task: Task, comptime method: InvokeMethod) type {
    const deinitFn = if (task.input != null) &AsyncInput(task.In(false)).deallocate else null;
    return struct {
        pub const vtable = switch (method) {
            .sync => unreachable,
            .asyncd => Invocation.Async.VTable{ .deinit = deinitFn, .invoke = invokeAsync },
            .callback => Invocation.Callback.VTable{ .deinit = deinitFn, .invoke = invokeCallback },
        };

        fn invokeAsync(tracer: ScheduleTracer, delegate: *const Delegate, in: ?*const anyopaque) anyerror!void {
            return invokeTask(tracer, delegate, in);
        }

        fn invokeTask(tracer: ScheduleTracer, delegate: *const Delegate, in: ?*const anyopaque) task.Out(.retain) {
            const sample = tracer.begin();
            defer sample.didInvoke(method, ComptimeTag.of(task));
            const input = if (task.input != null) AsyncInput(task.In(false)).cast(in.?).* else .{};
            return task.invoke(delegate, input);
        }

        fn invokeCallback(
            tracer: ScheduleTracer,
            delegate: *const Delegate,
            input: ?*const anyopaque,
            ctx: *const anyopaque,
            callback: *const anyopaque,
        ) anyerror!void {
            // If the inocation fails we pass the error to the callback to handle it (or return it).
            const output = invokeTask(tracer, delegate, input);

            const sample = tracer.begin();
            defer sample.didCallback(ComptimeTag.of(callback), ctx);
            const cb: Task.Callback(task) = @alignCast(@ptrCast(callback));
            if (task.Out(.retain) == void) try cb(ctx) else try cb(ctx, output);
        }
    };
}

test "AsyncInvoker" {
    tsk.tests.did_call = false;
    const IvkAsync = AsyncInvoker(tsk.tests.Call, .asyncd);
    try IvkAsync.invokeAsync(NoOpTracer.any, &scp.NOOP_DELEGATE, null);
    try testing.expect(tsk.tests.did_call);

    const InpCb = AsyncInput(tsk.tests.Multiply.In(false));
    const input = try InpCb.allocate(test_alloc, .{ 2, 54 });
    defer InpCb.deallocate(test_alloc, input.?);

    const IvkCb = AsyncInvoker(tsk.tests.Multiply, .callback);
    try IvkCb.invokeCallback(
        NoOpTracer.any,
        &scp.NOOP_DELEGATE,
        input,
        &@as(usize, 108),
        tests.multiplyCb,
    );
}

pub const ScheduleResources = struct {
    allocator: Allocator,
    scopes: util.Pool(Scope) = .{
        .createItem = createScope,
        .destroyItem = destroyScope,
        .resetItem = resetScope,
    },
    invocations: util.Pool(ScheduleNode) = .{
        .createItem = createInvocation,
        .destroyItem = destroyInvocation,
        .resetItem = resetInvocation,
    },

    pub fn init(allocator: Allocator) ScheduleResources {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ScheduleResources) void {
        self.scopes.deinit(self.allocator);
        self.invocations.deinit(self.allocator);
    }

    pub fn retainScope(self: *ScheduleResources) !*Scope {
        return self.scopes.retain(self.allocator);
    }

    pub fn releaseScope(self: *ScheduleResources, scope: *Scope) void {
        self.scopes.release(self.allocator, scope);
    }

    pub fn retainInvocation(self: *ScheduleResources) !*ScheduleNode {
        return self.invocations.retain(self.allocator);
    }

    pub fn releaseInvocation(self: *ScheduleResources, node: *ScheduleNode) void {
        self.invocations.release(self.allocator, node);
    }

    pub fn releaseQueue(self: *ScheduleResources, queue: *ScheduleQueue) void {
        while (queue.take()) |node| {
            node.value.cleanup(self.allocator);
            self.releaseQueue(&node.children);
            self.releaseInvocation(node);
        }
    }

    fn createScope(allocator: Allocator) !*Scope {
        const child_alloc = if (@import("builtin").is_test) test_alloc else std.heap.page_allocator;
        const scope = try allocator.create(Scope);
        scope.* = Scope.init(child_alloc, null);
        return scope;
    }

    fn destroyScope(allocator: Allocator, scope: *Scope) void {
        scope.deinit();
        allocator.destroy(scope);
    }

    fn resetScope(scope: *Scope) void {
        scope.reset();
    }

    fn createInvocation(allocator: Allocator) !*ScheduleNode {
        return ScheduleNode.init(allocator, .invalid);
    }

    fn destroyInvocation(allocator: Allocator, node: *ScheduleNode) void {
        allocator.destroy(node);
    }

    fn resetInvocation(node: *ScheduleNode) void {
        node.value = .invalid;
    }
};

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
            .start = std.time.Instant.now() catch unreachable,
        };
    }

    pub const Sample = struct {
        ctx: *anyopaque,
        vtable: *const VTable,
        start: std.time.Instant,

        pub fn didInvoke(self: Sample, method: InvokeMethod, task: ComptimeTag) void {
            const elapsed_ns = self.sample().since(self.start);
            self.vtable.didInvoke(self.ctx, method, task, elapsed_ns);
        }

        pub fn didCallback(self: Sample, callback: ComptimeTag, context: *const anyopaque) void {
            const elapsed_ns = self.sample().since(self.start);
            self.vtable.didCallback(self.ctx, callback, context, elapsed_ns);
        }

        fn sample(self: Sample) std.time.Instant {
            const current = std.time.Instant.now() catch unreachable;
            return if (current.order(self.start) == .gt) current else self.start;
        }
    };
};

const NoOpTracer = struct {
    var noop = .{};
    pub const any = ScheduleTracer{
        .ctx = &noop,
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
    resources: *ScheduleResources,
    root_scope: *Scope,
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
        errdefer test_alloc.destroy(tester);

        const resource = try test_alloc.create(ScheduleResources);
        resource.* = ScheduleResources.init(test_alloc);
        errdefer test_alloc.destroy(resource);

        const scope = try resource.retainScope();
        errdefer resource.releaseScope(scope);

        tester.* = .{
            .schedule = Schedule.init(test_alloc, resource, scope),
            .resources = resource,
            .root_scope = scope,
        };
        tester.schedule.tracer = .{ .ctx = tester, .vtable = &tracer };
        return tester;
    }

    pub fn deinit(self: *ScheduleTester) void {
        self.schedule.deinit();
        self.resources.releaseScope(self.root_scope);
        self.resources.deinit();
        self.invoke_records.deinit(test_alloc);
        self.callback_records.deinit(test_alloc);
        test_alloc.destroy(self.resources);
        test_alloc.destroy(self);
    }

    pub fn resetScope(self: *ScheduleTester) void {
        self.root_scope.reset();
    }

    pub fn resetTrace(self: *ScheduleTester) void {
        self.invoke_records.clearRetainingCapacity();
        self.callback_records.clearRetainingCapacity();
    }

    pub fn provideService(self: *ScheduleTester, service: anytype) !util.Reference(@TypeOf(service)) {
        return self.root_scope.provideService(service, null);
    }

    pub fn defineScopeValue(self: *ScheduleTester, comptime T: type, comptime tag: anytype, value: T) !void {
        try self.root_scope.defineValue(T, tag, value);
    }

    pub fn writeScopeValue(self: *ScheduleTester, comptime T: type, comptime tag: anytype, value: T) !void {
        try self.root_scope.writeValue(T, tag, value);
    }

    pub fn invokeSync(self: *ScheduleTester, comptime task: Task, input: task.In(false)) !task.Out(.strip) {
        return self.schedule.invokeSync(null, task, input);
    }

    pub inline fn invokeSyncExpectError(
        self: *ScheduleTester,
        expected: anyerror,
        comptime task: Task,
        input: task.In(false),
    ) !void {
        const output = self.schedule.invokeSync(null, task, input);
        try testing.expectError(expected, output);
    }

    pub fn scheduleAsync(self: *ScheduleTester, comptime task: Task, input: task.In(false)) !void {
        try self.schedule.appendAsync(null, task, input);
    }

    pub fn scheduleCallback(
        self: *ScheduleTester,
        comptime task: Task,
        input: task.In(false),
        context: *const anyopaque,
        callback: Task.Callback(task),
    ) !void {
        try self.schedule.appendCallback(null, task, input, context, callback);
    }

    pub fn evaluate(self: *ScheduleTester) !void {
        try self.schedule.evaluate();
    }

    pub inline fn runExpectError(self: *ScheduleTester, expected: anyerror) !void {
        try testing.expectError(expected, self.schedule.evaluate());
    }

    pub fn expectInvoke(
        self: ScheduleTester,
        order: usize,
        method: InvokeMethod,
        comptime task: Task,
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

    pub fn expectScopeValue(self: ScheduleTester, comptime T: type, comptime tag: anytype, expected: T) !void {
        const actual = self.root_scope.readValue(usize, tag);
        try testing.expectEqualDeep(expected, actual);
    }
};

test "invokeSync" {
    var tester = try ScheduleTester.init();
    defer tester.deinit();

    try tester.invokeSync(tsk.tests.Call, .{});
    try tester.invokeSync(tsk.tests.Failable, .{false});
    try tester.invokeSyncExpectError(error.Fail, tsk.tests.Failable, .{true});

    try tester.expectInvoke(0, .sync, tsk.tests.Call);
    try tester.expectInvoke(1, .sync, tsk.tests.Failable);
    try tester.expectInvoke(2, .sync, tsk.tests.Failable);
}

test "appendAsync" {
    var tester = try ScheduleTester.init();
    defer tester.deinit();

    try tester.scheduleAsync(tsk.tests.Call, .{});
    try tester.scheduleAsync(tsk.tests.Failable, .{false});
    try tester.scheduleAsync(tsk.tests.Failable, .{true});
    try tester.runExpectError(error.Fail);

    try tester.expectInvoke(0, .asyncd, tsk.tests.Call);
    try tester.expectInvoke(1, .asyncd, tsk.tests.Failable);
    try tester.expectInvoke(2, .asyncd, tsk.tests.Failable);
}

test "appendCallback" {
    var tester = try ScheduleTester.init();
    defer tester.deinit();

    try tester.scheduleCallback(tsk.tests.Multiply, .{ 2, 54 }, &@as(usize, 108), tests.multiplyCb);
    try tester.scheduleCallback(tsk.tests.Call, .{}, &@as(usize, 101), tests.noopCb);
    try tester.scheduleCallback(tsk.tests.Failable, .{false}, &@as(usize, 102), tests.failableCb);
    try tester.scheduleCallback(tsk.tests.Failable, .{true}, &@as(usize, 103), tests.failableCb);
    try tester.runExpectError(error.Fail);

    try tester.expectInvoke(0, .callback, tsk.tests.Multiply);
    try tester.expectCallback(0, tests.multiplyCb, &@as(usize, 108));
    try tester.expectInvoke(1, .callback, tsk.tests.Call);
    try tester.expectCallback(1, tests.noopCb, &@as(usize, 101));
    try tester.expectInvoke(2, .callback, tsk.tests.Failable);
    try tester.expectCallback(2, tests.failableCb, &@as(usize, 102));
    try tester.expectInvoke(3, .callback, tsk.tests.Failable);
    try tester.expectCallback(3, tests.failableCb, &@as(usize, 103));
}

test "sub-tasks scheduling" {
    const tasks = struct {
        pub const Root = Task.define("Root", root, .{});
        pub fn root(task: *const Delegate) anyerror!void {
            try task.scheduleAsync(Bar, .{});
            try task.invokeSync(Foo, .{});
            try task.scheduleCallback(Baz, .{}, undefined, tests.noopCb);
        }

        pub const Foo = Task.define("Foo", tsk.tests.noOp, .{});
        pub const Bar = Task.define("Bar", tsk.tests.noOp, .{});
        pub const Baz = Task.define("Baz", tsk.tests.noOp, .{});
    };

    var tester = try ScheduleTester.init();
    defer tester.deinit();

    try tester.scheduleAsync(tasks.Root, .{});
    try tester.evaluate();

    try tester.expectInvoke(0, .sync, tasks.Foo);
    try tester.expectInvoke(1, .asyncd, tasks.Root);
    try tester.expectInvoke(2, .asyncd, tasks.Bar);
    try tester.expectInvoke(3, .callback, tasks.Baz);
}

test "scopes" {
    var tester = try ScheduleTester.init();
    defer tester.deinit();

    try tester.defineScopeValue(usize, .num, 54);
    try tester.invokeSync(tests.MultiplyScope, .{2});
    try tester.expectScopeValue(usize, .num, 108);

    try tester.writeScopeValue(usize, .num, 267);
    try tester.scheduleAsync(tests.MultiplyScope, .{3});
    try tester.evaluate();
    try tester.expectScopeValue(usize, .num, 801);

    try tester.writeScopeValue(usize, .num, 27);
    try tester.scheduleAsync(tests.ExponentScope, .{2});
    try tester.evaluate();
    try tester.expectScopeValue(usize, .num, 108);

    try tester.defineScopeValue(usize, .mult, 54);
    try tester.scheduleAsync(tests.MultiplySubScope, .{2});
    try tester.evaluate();
    try tester.expectScopeValue(usize, .mult, 108);
}

const tests = struct {
    pub const MultiplyScope = Task.define("MultiplyScope", multiplyScope, .{});
    fn multiplyScope(task: *const Delegate, n: usize) !void {
        const m = task.readValue(usize, .num) orelse return error.MissingValue;
        try task.writeValue(usize, .num, m * n);
    }

    pub const ExponentScope = Task.define("ExponentScope", exponentScope, .{});
    fn exponentScope(task: *const Delegate, n: usize) !void {
        try task.scheduleAsync(MultiplyScope, .{n});
        const m = task.readValue(usize, .num) orelse return error.MissingValue;
        try task.writeValue(usize, .num, m * n);
    }

    pub const MultiplySubScope = Task.define("MultiplySubScope", multiplySubScope, .{});
    fn multiplySubScope(task: *const Delegate, n: usize) !void {
        const m = task.readValue(usize, .mult) orelse return error.MissingValue;
        try task.defineValue(usize, .num, n);
        try task.invokeSync(MultiplyScope, .{m});
        const prod = task.readValue(usize, .num) orelse return error.MissingValue;
        try task.writeValue(usize, .mult, prod);
    }

    pub fn noopCb(_: *const anyopaque) anyerror!void {}

    pub fn failableCb(_: *const anyopaque, output: error{Fail}!void) anyerror!void {
        try output;
    }

    pub fn multiplyCb(ctx: *const anyopaque, output: usize) anyerror!void {
        try testing.expectEqual(castUsize(ctx), output);
    }

    fn castUsize(ctx: *const anyopaque) usize {
        const cast: *const usize = @alignCast(@ptrCast(ctx));
        return cast.*;
    }
};
