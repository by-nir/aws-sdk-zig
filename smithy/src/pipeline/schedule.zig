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
    tracer: ivk.InvokeTracer,

    pub const Options = struct {
        tracer: ivk.InvokeTracer = ivk.NOOP_TRACER,
    };

    pub fn init(allocator: Allocator, resources: *ScheduleResources, scope: *Scope, options: Options) Schedule {
        return .{
            .allocator = allocator,
            .resources = resources,
            .root_scope = scope,
            .tracer = options.tracer,
        };
    }

    pub fn deinit(self: *Schedule) void {
        self.resources.releaseQueue(&self.queue);
    }

    pub fn evaluateSync(
        self: *Schedule,
        parent: ?*const Delegate,
        comptime task: Task,
        input: task.In,
    ) !task.Payload() {
        var delegate = self.delegateFor(if (parent) |p| p.scope else self.root_scope);
        defer if (delegate.branchScope == null) self.resources.releaseScope(delegate.scope);
        errdefer self.resources.releaseQueue(&delegate.children);

        const output = delegate.scope.invoker.evaluateSync(task, self.tracer, &delegate, input);
        _ = if (comptime task.isFailable()) output catch |err| return err;

        try self.evaluateQueue(delegate.scope, &delegate.children);
        return output;
    }

    pub fn appendAsync(self: *Schedule, parent: ?*const Delegate, comptime task: Task, input: task.In) !void {
        if (task.Payload() != void)
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
        input: task.In,
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

test "tasks" {
    var resources = ScheduleResources.init(test_alloc);
    defer resources.deinit();

    const scope = try resources.retainScope();
    defer resources.releaseScope(scope);

    var recorder = ivk.InvokeTraceRecorder.init(test_alloc);
    defer recorder.deinit();

    var schedule = Schedule.init(test_alloc, &resources, scope, .{
        .tracer = recorder.tracer(),
    });
    defer schedule.deinit();

    //
    // Sync
    //

    try schedule.evaluateSync(null, tests.Call, .{});
    try recorder.expectInvoke(0, .sync, tests.Call);

    try schedule.evaluateSync(null, tests.Failable, .{false});
    try recorder.expectInvoke(1, .sync, tests.Failable);

    try testing.expectError(
        error.Fail,
        schedule.evaluateSync(null, tests.Failable, .{true}),
    );
    try recorder.expectInvoke(2, .sync, tests.Failable);

    recorder.clear();

    //
    // Async
    //

    try schedule.appendAsync(null, tests.Call, .{});
    try schedule.appendAsync(null, tests.Failable, .{false});
    try schedule.appendAsync(null, tests.Failable, .{true});

    try testing.expectError(error.Fail, schedule.evaluate());

    try recorder.expectInvoke(0, .asyncd, tests.Call);
    try recorder.expectInvoke(1, .asyncd, tests.Failable);
    try recorder.expectInvoke(2, .asyncd, tests.Failable);

    recorder.clear();

    //
    // Callback
    //

    try schedule.appendCallback(null, tests.Multiply, .{ 2, 54 }, &@as(usize, 108), tests.multiplyCb);
    try schedule.appendCallback(null, tests.Call, .{}, &@as(usize, 101), tests.noopCb);
    try schedule.appendCallback(null, tests.Failable, .{false}, &@as(usize, 102), tests.failableCb);
    try schedule.appendCallback(null, tests.Failable, .{true}, &@as(usize, 103), tests.failableCb);

    try testing.expectError(error.Fail, schedule.evaluate());

    try recorder.expectInvoke(0, .callback, tests.Multiply);
    try recorder.expectCallback(0, tests.multiplyCb, &@as(usize, 108));

    try recorder.expectInvoke(1, .callback, tests.Call);
    try recorder.expectCallback(1, tests.noopCb, &@as(usize, 101));

    try recorder.expectInvoke(2, .callback, tests.Failable);
    try recorder.expectCallback(2, tests.failableCb, &@as(usize, 102));

    try recorder.expectInvoke(3, .callback, tests.Failable);
    try recorder.expectCallback(3, tests.failableCb, &@as(usize, 103));
}

test "sub-tasks" {
    var resources = ScheduleResources.init(test_alloc);
    defer resources.deinit();

    const scope = try resources.retainScope();
    defer resources.releaseScope(scope);

    var recorder = ivk.InvokeTraceRecorder.init(test_alloc);
    defer recorder.deinit();

    var schedule = Schedule.init(test_alloc, &resources, scope, .{
        .tracer = recorder.tracer(),
    });
    defer schedule.deinit();

    const sub = struct {
        pub const Root = Task.Define("Root", root, .{});
        pub fn root(self: *const Delegate) anyerror!void {
            try self.schedule(Bar, .{});
            try self.evaluate(Foo, .{});
            try self.scheduleCallback(Baz, .{}, undefined, tests.noopCb);
        }

        pub const Foo = Task.Define("Foo", tests.noOpFn, .{});
        pub const Bar = Task.Define("Bar", tests.noOpFn, .{});
        pub const Baz = Task.Define("Baz", tests.noOpFn, .{});
    };

    try schedule.appendAsync(null, sub.Root, .{});
    try schedule.evaluate();

    try recorder.expectInvoke(0, .sync, sub.Foo);
    try recorder.expectInvoke(1, .asyncd, sub.Root);
    try recorder.expectInvoke(2, .asyncd, sub.Bar);
    try recorder.expectInvoke(3, .callback, sub.Baz);
}

test "scopes" {
    var resources = ScheduleResources.init(test_alloc);
    defer resources.deinit();

    const scope = try resources.retainScope();
    defer resources.releaseScope(scope);

    var schedule = Schedule.init(test_alloc, &resources, scope, .{});
    defer schedule.deinit();

    try scope.defineValue(usize, .num, 54);
    try schedule.evaluateSync(null, tests.MultiplyScope, .{2});
    try testing.expectEqualDeep(108, scope.readValue(usize, .num));

    scope.reset();

    try scope.defineValue(usize, .num, 267);
    try schedule.appendAsync(null, tests.MultiplyScope, .{3});
    try schedule.evaluate();
    try testing.expectEqualDeep(801, scope.readValue(usize, .num));

    scope.reset();

    try scope.defineValue(usize, .num, 27);
    try schedule.appendAsync(null, tests.ExponentScope, .{2});
    try schedule.evaluate();
    try testing.expectEqualDeep(108, scope.readValue(usize, .num));

    scope.reset();

    try scope.defineValue(usize, .mult, 54);
    try schedule.appendAsync(null, tests.MultiplySubScope, .{2});
    try schedule.evaluate();
    try testing.expectEqualDeep(108, scope.readValue(usize, .mult));

    scope.reset();

    var value = try schedule.evaluateSync(null, tests.OptInjectMultiply, .{54});
    try testing.expectEqual(54, value);

    _ = try scope.provideService(tests.Service{ .value = 2 }, null);

    value = try schedule.evaluateSync(null, tests.OptInjectMultiply, .{54});
    try testing.expectEqual(108, value);

    value = try schedule.evaluateSync(null, tests.InjectMultiply, .{54});
    try testing.expectEqual(108, value);
}
