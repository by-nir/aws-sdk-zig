const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const tsk = @import("task.zig");
const Task = tsk.Task;
const Delegate = tsk.Delegate;
const ivk = @import("invoke.zig");
const Scope = @import("scope.zig").Scope;
const util = @import("utils.zig");
const ComptimeTag = util.ComptimeTag;
const tests = @import("tests.zig");

const ScheduleNode = util.Node(ivk.AsyncInvocation);
pub const ScheduleQueue = util.Queue(ivk.AsyncInvocation);

pub const Schedule = struct {
    allocator: Allocator,
    resources: *ScheduleResources,
    root_scope: *Scope,
    queue: ScheduleQueue = .{},
    tracer: ivk.InvokeTracer = ivk.NOOP_TRACER,

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

    pub fn evaluateSync(
        self: *Schedule,
        parent: ?*const Delegate,
        comptime task: Task,
        input: task.In(false),
    ) !task.Out(.strip) {
        var delegate = self.delegateFor(if (parent) |p| p.scope else self.root_scope);
        defer if (delegate.branchScope == null) self.resources.releaseScope(delegate.scope);
        errdefer self.resources.releaseQueue(&delegate.children);

        const output = delegate.scope.invoker.evaluateSync(task, self.tracer, &delegate, input);
        if (task.Out(.strip) != task.Out(.retain)) try output;

        try self.evaluateQueue(delegate.scope, &delegate.children);
        return output;
    }

    pub fn appendAsync(self: *Schedule, parent: ?*const Delegate, comptime task: Task, input: task.In(false)) !void {
        if (task.Out(.strip) != void)
            @compileError("Task '" ++ task.name ++ "' returns a value, use `appendAsync` instead.");

        const scope = if (parent) |p| p.scope else self.root_scope;

        const node = try self.resources.retainInvocation();
        errdefer self.resources.releaseInvocation(node);
        node.value = try scope.invoker.prepareAsync(scope.alloc(), task, input);

        const queue = if (parent) |p| @constCast(&p.children) else &self.queue;
        queue.put(node);
    }

    pub fn appendCallback(
        self: *Schedule,
        parent: ?*const Delegate,
        comptime task: Task,
        input: task.In(false),
        callbackCtx: *const anyopaque,
        callbackFn: Task.Callback(task),
    ) !void {
        const scope = if (parent) |p| p.scope else self.root_scope;

        const node = try self.resources.retainInvocation();
        errdefer self.resources.releaseInvocation(node);
        node.value = try scope.invoker.prepareCallback(scope.alloc(), task, input, callbackCtx, callbackFn);

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
        const parent = delegate.scope;
        const self = delegate.scheduler;

        const child = try self.resources.retainScope();
        child.parent = parent;
        child.invoker = parent.invoker;

        const mutable: *Delegate = @constCast(delegate);
        mutable.scope = child;
        mutable.branchScope = null;
    }
};

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
            // node.value.cleanup(self.allocator);
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
        return ScheduleNode.init(allocator, undefined);
    }

    fn destroyInvocation(allocator: Allocator, node: *ScheduleNode) void {
        allocator.destroy(node);
    }

    fn resetInvocation(node: *ScheduleNode) void {
        node.value = undefined;
    }
};

pub const ScheduleTester = struct {
    schedule: Schedule,
    resources: *ScheduleResources,
    root_scope: *Scope,
    invoke_records: std.ArrayListUnmanaged(InvokeRecord) = .{},
    callback_records: std.ArrayListUnmanaged(CallbackRecord) = .{},

    const InvokeRecord = struct { method: ivk.InvokeMethod, task: ComptimeTag };
    const CallbackRecord = struct { callback: ComptimeTag, context: *const anyopaque };

    const tracer = ivk.InvokeTracer.VTable{
        .didEvaluate = didInvoke,
        .didCallback = didCallback,
    };

    fn didInvoke(ctx: *anyopaque, method: ivk.InvokeMethod, task: ComptimeTag, _: u64) void {
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

    pub fn evaluateSync(self: *ScheduleTester, comptime task: Task, input: task.In(false)) !task.Out(.strip) {
        return self.schedule.evaluateSync(null, task, input);
    }

    pub inline fn evaluateSyncExpectError(
        self: *ScheduleTester,
        expected: anyerror,
        comptime task: Task,
        input: task.In(false),
    ) !void {
        const output = self.schedule.evaluateSync(null, task, input);
        try testing.expectError(expected, output);
    }

    pub fn scheduleAsync(self: *ScheduleTester, comptime task: Task, input: task.In(false)) !void {
        try self.schedule.appendAsync(null, task, input);
    }

    pub fn scheduleCallback(
        self: *ScheduleTester,
        comptime task: Task,
        input: task.In(false),
        callbackCtx: *const anyopaque,
        callbackFn: Task.Callback(task),
    ) !void {
        try self.schedule.appendCallback(null, task, input, callbackCtx, callbackFn);
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
        method: ivk.InvokeMethod,
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

test "evaluateSync" {
    var tester = try ScheduleTester.init();
    defer tester.deinit();

    try tester.evaluateSync(tests.Call, .{});
    try tester.evaluateSync(tests.Failable, .{false});
    try tester.evaluateSyncExpectError(error.Fail, tests.Failable, .{true});

    try tester.expectInvoke(0, .sync, tests.Call);
    try tester.expectInvoke(1, .sync, tests.Failable);
    try tester.expectInvoke(2, .sync, tests.Failable);
}

test "appendAsync" {
    var tester = try ScheduleTester.init();
    defer tester.deinit();

    try tester.scheduleAsync(tests.Call, .{});
    try tester.scheduleAsync(tests.Failable, .{false});
    try tester.scheduleAsync(tests.Failable, .{true});
    try tester.runExpectError(error.Fail);

    try tester.expectInvoke(0, .asyncd, tests.Call);
    try tester.expectInvoke(1, .asyncd, tests.Failable);
    try tester.expectInvoke(2, .asyncd, tests.Failable);
}

test "appendCallback" {
    var tester = try ScheduleTester.init();
    defer tester.deinit();

    try tester.scheduleCallback(tests.Multiply, .{ 2, 54 }, &@as(usize, 108), tests.multiplyCb);
    try tester.scheduleCallback(tests.Call, .{}, &@as(usize, 101), tests.noopCb);
    try tester.scheduleCallback(tests.Failable, .{false}, &@as(usize, 102), tests.failableCb);
    try tester.scheduleCallback(tests.Failable, .{true}, &@as(usize, 103), tests.failableCb);
    try tester.runExpectError(error.Fail);

    try tester.expectInvoke(0, .callback, tests.Multiply);
    try tester.expectCallback(0, tests.multiplyCb, &@as(usize, 108));
    try tester.expectInvoke(1, .callback, tests.Call);
    try tester.expectCallback(1, tests.noopCb, &@as(usize, 101));
    try tester.expectInvoke(2, .callback, tests.Failable);
    try tester.expectCallback(2, tests.failableCb, &@as(usize, 102));
    try tester.expectInvoke(3, .callback, tests.Failable);
    try tester.expectCallback(3, tests.failableCb, &@as(usize, 103));
}

test "sub-tasks scheduling" {
    const tasks = struct {
        pub const Root = Task.define("Root", root, .{});
        pub fn root(self: *const Delegate) anyerror!void {
            try self.schedule(Bar, .{});
            try self.evaluate(Foo, .{});
            try self.scheduleCallback(Baz, .{}, undefined, tests.noopCb);
        }

        pub const Foo = Task.define("Foo", tests.noOpFn, .{});
        pub const Bar = Task.define("Bar", tests.noOpFn, .{});
        pub const Baz = Task.define("Baz", tests.noOpFn, .{});
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
    try tester.evaluateSync(tests.MultiplyScope, .{2});
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

    var value = try tester.evaluateSync(tests.OptInjectMultiply, .{54});
    try testing.expectEqual(54, value);

    _ = try tester.provideService(tests.Service{ .value = 2 });

    value = try tester.evaluateSync(tests.OptInjectMultiply, .{54});
    try testing.expectEqual(108, value);

    value = try tester.evaluateSync(tests.InjectMultiply, .{54});
    try testing.expectEqual(108, value);
}
