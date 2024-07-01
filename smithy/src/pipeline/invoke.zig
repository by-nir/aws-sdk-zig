const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const tsk = @import("task.zig");
const Task = tsk.Task;
const Delegate = tsk.Delegate;
const ComptimeTag = @import("utils.zig").ComptimeTag;
const tests = @import("tests.zig");

pub const InvokeMethod = enum { sync, asyncd, callback };

pub const InvokeOverrideFn = *const fn (tag: ComptimeTag) ?OpaqueEvaluator;

pub const Invoker = struct {
    overrides: InvokeOverrideFn = noOverides,

    pub fn evaluateSync(
        self: Invoker,
        comptime task: Task,
        tracer: InvokeTracer,
        delegate: *const Delegate,
        input: task.In(false),
    ) task.Out(.retain) {
        const evalFn = self.getOpaqueEval(task, .sync);

        var out: task.Out(.retain) = undefined;
        evalFn(tracer, delegate, &input, &out);
        return out;
    }

    pub fn prepareAsync(
        self: Invoker,
        arena: Allocator,
        comptime task: Task,
        input: task.In(false),
    ) !AsyncInvocation {
        const evalFn = self.getOpaqueEval(task, .asyncd);
        return AsyncInvocation.allocAsync(arena, input, evalFn);
    }

    pub fn prepareCallback(
        self: Invoker,
        arena: Allocator,
        comptime task: Task,
        input: task.In(false),
        callbackCtx: *const anyopaque,
        callbackFn: Task.Callback(task),
    ) !AsyncInvocation {
        const evalFn = self.getOpaqueEval(task, .callback);
        return AsyncInvocation.allocCallback(arena, input, evalFn, callbackCtx, callbackFn);
    }

    pub fn hasOverride(self: Invoker, comptime task: Task) bool {
        const tag = ComptimeTag.of(task);
        return self.overrides(tag) != null;
    }

    fn getOpaqueEval(self: Invoker, comptime task: Task, comptime method: InvokeMethod) OpaqueEvaluator.Func(method) {
        const tag = ComptimeTag.of(task);
        const vtable = self.overrides(tag) orelse OpaqueEvaluator.of(task);
        return vtable.func(method);
    }

    fn noOverides(_: ComptimeTag) ?OpaqueEvaluator {
        return null;
    }
};

pub const AsyncInvocation = struct {
    method: InvokeMethod,
    payload: *allowzero const anyopaque,
    evalFn: *const anyopaque,

    fn AsyncPaylod(comptime In: type) type {
        return struct { input: In };
    }

    fn CallbackPaylod(comptime In: type, comptime Cb: type) type {
        return struct {
            input: In,
            callbackCtx: *const anyopaque,
            callbackFn: Cb,
        };
    }

    fn allocAsync(arena: Allocator, input: anytype, evalFn: OpaqueEvaluator.AsyncFn) !AsyncInvocation {
        const In: type = @TypeOf(input);
        const payload: *allowzero const anyopaque = if (In == void) null else blk: {
            const payload = try arena.create(AsyncPaylod(In));
            payload.* = .{ .input = input };
            break :blk payload;
        };

        return .{
            .method = .asyncd,
            .payload = payload,
            .evalFn = evalFn,
        };
    }

    fn allocCallback(
        arena: Allocator,
        input: anytype,
        evalFn: OpaqueEvaluator.CallbackFn,
        callbackCtx: *const anyopaque,
        callbackFn: anytype,
    ) !AsyncInvocation {
        const In: type = @TypeOf(input);
        const Cb: type = @TypeOf(callbackFn);
        const payload = try arena.create(CallbackPaylod(In, Cb));
        payload.* = .{
            .input = input,
            .callbackCtx = callbackCtx,
            .callbackFn = callbackFn,
        };

        return .{
            .method = .callback,
            .payload = payload,
            .evalFn = evalFn,
        };
    }

    pub fn evaluate(self: AsyncInvocation, tracer: InvokeTracer, delegate: *const Delegate) anyerror!void {
        switch (self.method) {
            .sync => unreachable,
            .asyncd => {
                const evalFn: OpaqueEvaluator.AsyncFn = @alignCast(@ptrCast(self.evalFn));
                return evalFn(tracer, delegate, self.payload);
            },
            .callback => {
                const evalFn: OpaqueEvaluator.CallbackFn = @alignCast(@ptrCast(self.evalFn));
                return evalFn(tracer, delegate, self.payload);
            },
        }
    }
};

pub const OpaqueEvaluator = struct {
    evalSyncFn: SyncFn,
    evalAsyncFn: AsyncFn,
    evalCallbackFn: CallbackFn,

    pub const SyncFn = *const fn (tracer: InvokeTracer, delegate: *const Delegate, input: *const anyopaque, output: *anyopaque) void;
    pub const AsyncFn = *const fn (tracer: InvokeTracer, delegate: *const Delegate, async_payload: *allowzero const anyopaque) anyerror!void;
    pub const CallbackFn = *const fn (tracer: InvokeTracer, delegate: *const Delegate, async_payload: *allowzero const anyopaque) anyerror!void;

    pub fn Func(comptime method: InvokeMethod) type {
        return switch (method) {
            .sync => SyncFn,
            .asyncd => AsyncFn,
            .callback => CallbackFn,
        };
    }

    pub fn func(self: OpaqueEvaluator, comptime method: InvokeMethod) Func(method) {
        return switch (method) {
            .sync => self.evalSyncFn,
            .asyncd => self.evalAsyncFn,
            .callback => self.evalCallbackFn,
        };
    }

    pub fn of(comptime task: Task) OpaqueEvaluator {
        const In = task.In(false);
        const Out = task.Out(.retain);
        const Cb = Task.Callback(task);
        const has_output = Out != void;
        const no_input = task.input == null;

        const eval = struct {
            fn evalSync(tracer: InvokeTracer, delegate: *const Delegate, in: *allowzero const anyopaque, out: *anyopaque) void {
                const sample = tracer.begin();
                defer sample.didEvaluate(.sync, ComptimeTag.of(task));

                const input = if (no_input) .{} else @as(*const In, @alignCast(@ptrCast(in))).*;
                if (has_output) {
                    const output: *Out = @alignCast(@ptrCast(out));
                    output.* = task.evaluate(delegate, input);
                } else {
                    task.evaluate(delegate, input);
                }
            }

            fn evalAsync(tracer: InvokeTracer, delegate: *const Delegate, async_payload: *allowzero const anyopaque) anyerror!void {
                const Payload = AsyncInvocation.AsyncPaylod(In);
                const input = if (no_input) .{} else blk: {
                    const payload: *const Payload = @alignCast(@ptrCast(async_payload));
                    break :blk payload.input;
                };

                const sample = tracer.begin();
                defer sample.didEvaluate(.asyncd, ComptimeTag.of(task));
                return task.evaluate(delegate, input);
            }

            fn evalCallback(tracer: InvokeTracer, delegate: *const Delegate, async_payload: *allowzero const anyopaque) anyerror!void {
                const Payload = AsyncInvocation.CallbackPaylod(In, Cb);
                const payload: *const Payload = @alignCast(@ptrCast(async_payload));

                const output = blk: {
                    const sample = tracer.begin();
                    defer sample.didEvaluate(.callback, ComptimeTag.of(task));
                    const input = if (no_input) .{} else payload.input;
                    break :blk task.evaluate(delegate, input);
                };

                const sample = tracer.begin();
                defer sample.didCallback(ComptimeTag.of(payload.callbackFn), payload.callbackCtx);
                if (has_output) {
                    try payload.callbackFn(payload.callbackCtx, output);
                } else {
                    try payload.callbackFn(payload.callbackCtx);
                }
            }
        };

        return OpaqueEvaluator{
            .evalSyncFn = eval.evalSync,
            .evalAsyncFn = if (task.Out(.strip) == void) eval.evalAsync else undefined,
            .evalCallbackFn = eval.evalCallback,
        };
    }
};

pub const InvokeTracer = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        didEvaluate: *const fn (ctx: *anyopaque, method: InvokeMethod, task: ComptimeTag, elapsed_ns: u64) void,
        didCallback: *const fn (ctx: *anyopaque, callback: ComptimeTag, context: *const anyopaque, elapsed_ns: u64) void,
    };

    pub fn begin(self: InvokeTracer) Sample {
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

        pub fn didEvaluate(self: Sample, method: InvokeMethod, task: ComptimeTag) void {
            const elapsed_ns = self.sample().since(self.start);
            self.vtable.didEvaluate(self.ctx, method, task, elapsed_ns);
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

pub const NOOP_TRACER = NoOpTracer.any;
const NoOpTracer = struct {
    var noop = .{};
    pub const any = InvokeTracer{
        .ctx = &noop,
        .vtable = &vtable,
    };

    const vtable = InvokeTracer.VTable{
        .didEvaluate = didEvaluate,
        .didCallback = didCallback,
    };

    fn didEvaluate(_: *anyopaque, _: InvokeMethod, _: ComptimeTag, _: u64) void {}

    fn didCallback(_: *anyopaque, _: ComptimeTag, _: *const anyopaque, _: u64) void {}
};

test "invoke sync" {
    const invoker = Invoker{};

    TracerTester.reset();
    invoker.evaluateSync(tests.Call, TracerTester.shared, &tsk.NOOP_DELEGATE, .{});
    try testing.expectEqual(InvokeMethod.sync, TracerTester.last_method);
    try testing.expectEqual(ComptimeTag.of(tests.Call), TracerTester.last_invoke);

    TracerTester.reset();
    try invoker.evaluateSync(tests.Failable, TracerTester.shared, &tsk.NOOP_DELEGATE, .{false});
    try testing.expectEqual(InvokeMethod.sync, TracerTester.last_method);
    try testing.expectEqual(ComptimeTag.of(tests.Failable), TracerTester.last_invoke);

    TracerTester.reset();
    try testing.expectError(
        error.Fail,
        invoker.evaluateSync(tests.Failable, TracerTester.shared, &tsk.NOOP_DELEGATE, .{true}),
    );
    try testing.expectEqual(InvokeMethod.sync, TracerTester.last_method);
    try testing.expectEqual(ComptimeTag.of(tests.Failable), TracerTester.last_invoke);
}

test "invoke async" {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const arena_alloc = arena.allocator();
    defer _ = arena.deinit();

    const invoker = Invoker{};

    TracerTester.reset();
    var invocation = try invoker.prepareAsync(arena_alloc, tests.Call, .{});
    try invocation.evaluate(TracerTester.shared, &tsk.NOOP_DELEGATE);
    try testing.expectEqual(InvokeMethod.asyncd, TracerTester.last_method);
    try testing.expectEqual(ComptimeTag.of(tests.Call), TracerTester.last_invoke);

    TracerTester.reset();
    invocation = try invoker.prepareAsync(arena_alloc, tests.Failable, .{false});
    try invocation.evaluate(TracerTester.shared, &tsk.NOOP_DELEGATE);
    try testing.expectEqual(InvokeMethod.asyncd, TracerTester.last_method);
    try testing.expectEqual(ComptimeTag.of(tests.Failable), TracerTester.last_invoke);

    invocation = try invoker.prepareAsync(arena_alloc, tests.Failable, .{true});
    try testing.expectError(
        error.Fail,
        invocation.evaluate(TracerTester.shared, &tsk.NOOP_DELEGATE),
    );
    try testing.expectEqual(InvokeMethod.asyncd, TracerTester.last_method);
    try testing.expectEqual(ComptimeTag.of(tests.Failable), TracerTester.last_invoke);

    TracerTester.reset();
    invocation = try invoker.prepareCallback(arena_alloc, tests.Call, .{}, "foo", tests.noopCb);
    try invocation.evaluate(TracerTester.shared, &tsk.NOOP_DELEGATE);
    try testing.expectEqual(InvokeMethod.callback, TracerTester.last_method);
    try testing.expectEqual(ComptimeTag.of(tests.Call), TracerTester.last_invoke);
    try testing.expectEqual(ComptimeTag.of(&tests.noopCb), TracerTester.last_callback);
    try testing.expectEqualDeep(@as(*const anyopaque, "foo"), TracerTester.last_context);

    TracerTester.reset();
    invocation = try invoker.prepareCallback(arena_alloc, tests.Failable, .{false}, "bar", tests.failableCb);
    try invocation.evaluate(TracerTester.shared, &tsk.NOOP_DELEGATE);
    try testing.expectEqual(InvokeMethod.callback, TracerTester.last_method);
    try testing.expectEqual(ComptimeTag.of(tests.Failable), TracerTester.last_invoke);
    try testing.expectEqual(ComptimeTag.of(&tests.failableCb), TracerTester.last_callback);
    try testing.expectEqualDeep(@as(*const anyopaque, "bar"), TracerTester.last_context);

    TracerTester.reset();
    invocation = try invoker.prepareCallback(arena_alloc, tests.Failable, .{true}, "baz", tests.failableCb);
    try testing.expectError(
        error.Fail,
        invocation.evaluate(TracerTester.shared, &tsk.NOOP_DELEGATE),
    );
    try testing.expectEqual(InvokeMethod.callback, TracerTester.last_method);
    try testing.expectEqual(ComptimeTag.of(tests.Failable), TracerTester.last_invoke);
    try testing.expectEqual(ComptimeTag.of(&tests.failableCb), TracerTester.last_callback);
    try testing.expectEqualDeep(@as(*const anyopaque, "baz"), TracerTester.last_context);
}

pub const TracerTester = struct {
    pub var last_method: ?InvokeMethod = null;
    pub var last_invoke: ComptimeTag = .invalid;
    pub var last_callback: ComptimeTag = .invalid;
    pub var last_context: ?*const anyopaque = null;

    pub const shared = InvokeTracer{
        .ctx = undefined,
        .vtable = &.{
            .didEvaluate = didInvoke,
            .didCallback = didCallback,
        },
    };

    fn didInvoke(_: *anyopaque, method: InvokeMethod, task: ComptimeTag, _: u64) void {
        last_method = method;
        last_invoke = task;
    }

    fn didCallback(_: *anyopaque, callback: ComptimeTag, context: *const anyopaque, _: u64) void {
        last_callback = callback;
        last_context = context;
    }

    pub fn reset() void {
        last_method = null;
        last_invoke = .invalid;
        last_callback = .invalid;
        last_context = null;
    }
};
