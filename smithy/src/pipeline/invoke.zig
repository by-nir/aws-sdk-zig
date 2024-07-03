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

pub const Invoker = struct {
    overrides: OverrideFn = noOverides,

    pub const OverrideFn = *const fn (tag: ComptimeTag) ?OpaqueEvaluator;

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

    var recorder = InvokeTracerRecorder.init(test_alloc);
    defer recorder.deinit();

    invoker.evaluateSync(tests.Call, recorder.tracer(), &tsk.NOOP_DELEGATE, .{});
    try recorder.expectInvoke(0, .sync, tests.Call);

    recorder.clear();
    try invoker.evaluateSync(tests.Failable, recorder.tracer(), &tsk.NOOP_DELEGATE, .{false});
    try recorder.expectInvoke(0, .sync, tests.Failable);

    recorder.clear();
    try testing.expectError(
        error.Fail,
        invoker.evaluateSync(tests.Failable, recorder.tracer(), &tsk.NOOP_DELEGATE, .{true}),
    );
    try recorder.expectInvoke(0, .sync, tests.Failable);
}

test "invoke async" {
    const invoker = Invoker{};

    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const arena_alloc = arena.allocator();
    defer _ = arena.deinit();

    var recorder = InvokeTracerRecorder.init(test_alloc);
    defer recorder.deinit();

    var invocation = try invoker.prepareAsync(arena_alloc, tests.Call, .{});
    try invocation.evaluate(recorder.tracer(), &tsk.NOOP_DELEGATE);
    try recorder.expectInvoke(0, .asyncd, tests.Call);

    recorder.clear();
    invocation = try invoker.prepareAsync(arena_alloc, tests.Failable, .{false});
    try invocation.evaluate(recorder.tracer(), &tsk.NOOP_DELEGATE);
    try recorder.expectInvoke(0, .asyncd, tests.Failable);

    recorder.clear();
    invocation = try invoker.prepareAsync(arena_alloc, tests.Failable, .{true});
    try testing.expectError(
        error.Fail,
        invocation.evaluate(recorder.tracer(), &tsk.NOOP_DELEGATE),
    );
    try recorder.expectInvoke(0, .asyncd, tests.Failable);

    recorder.clear();
    invocation = try invoker.prepareCallback(arena_alloc, tests.Call, .{}, "foo", tests.noopCb);
    try invocation.evaluate(recorder.tracer(), &tsk.NOOP_DELEGATE);
    try recorder.expectInvoke(0, .callback, tests.Call);
    try recorder.expectCallback(0, tests.noopCb, "foo");

    recorder.clear();
    invocation = try invoker.prepareCallback(arena_alloc, tests.Failable, .{false}, "bar", tests.failableCb);
    try invocation.evaluate(recorder.tracer(), &tsk.NOOP_DELEGATE);
    try recorder.expectInvoke(0, .callback, tests.Failable);
    try recorder.expectCallback(0, tests.failableCb, "bar");

    recorder.clear();
    invocation = try invoker.prepareCallback(arena_alloc, tests.Failable, .{true}, "baz", tests.failableCb);
    try testing.expectError(
        error.Fail,
        invocation.evaluate(recorder.tracer(), &tsk.NOOP_DELEGATE),
    );
    try recorder.expectInvoke(0, .callback, tests.Failable);
    try recorder.expectCallback(0, tests.failableCb, "baz");
}

pub const InvokeTracerRecorder = struct {
    allocator: Allocator,
    invoke_records: std.ArrayListUnmanaged(InvokeRecord) = .{},
    callback_records: std.ArrayListUnmanaged(CallbackRecord) = .{},

    const InvokeRecord = struct { method: InvokeMethod, task: ComptimeTag };
    const CallbackRecord = struct { callback: ComptimeTag, context: *const anyopaque };

    pub fn init(allocator: Allocator) InvokeTracerRecorder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *InvokeTracerRecorder) void {
        self.invoke_records.deinit(self.allocator);
        self.callback_records.deinit(self.allocator);
    }

    pub fn tracer(self: *InvokeTracerRecorder) InvokeTracer {
        return .{
            .ctx = self,
            .vtable = &.{
                .didEvaluate = didInvoke,
                .didCallback = didCallback,
            },
        };
    }

    fn didInvoke(ctx: *anyopaque, method: InvokeMethod, task: ComptimeTag, _: u64) void {
        const record = .{ .method = method, .task = task };
        const self: *InvokeTracerRecorder = @ptrCast(@alignCast(ctx));
        self.invoke_records.append(self.allocator, record) catch @panic("OOM");
    }

    fn didCallback(ctx: *anyopaque, callback: ComptimeTag, context: *const anyopaque, _: u64) void {
        const record = .{ .callback = callback, .context = context };
        const self: *InvokeTracerRecorder = @ptrCast(@alignCast(ctx));
        self.callback_records.append(self.allocator, record) catch @panic("OOM");
    }

    pub fn clear(self: *InvokeTracerRecorder) void {
        self.invoke_records.clearRetainingCapacity();
        self.callback_records.clearRetainingCapacity();
    }

    pub fn expectInvoke(
        self: *InvokeTracerRecorder,
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
        self: *InvokeTracerRecorder,
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

pub const TasksOverrider = struct {
    comptime map: std.BoundedArray(Mapping, 128) = .{},

    const Mapping = struct {
        task: Task,
        evaluator: OpaqueEvaluator,
    };

    pub fn override(
        comptime self: *TasksOverrider,
        comptime task: Task,
        comptime name: []const u8,
        comptime func: anytype,
        comptime options: Task.Options,
    ) Task {
        const o_task = Task.define("[OVERRIDE] " ++ name, func, options);
        if (o_task.output != task.output) {
            @compileError("Override '" ++ name ++ "' expects output type " ++ @typeName(task.output));
        } else if (task.input != null or o_task.input != null) {
            const task_len = if (task.input) |in| in.len else 0;
            const ovrd_len = if (o_task.input) |in| in.len else 0;
            if (task_len != ovrd_len) {
                const message = "Override '{s}' expects {d} input parameters";
                @compileError(std.fmt.comptimePrint(message, .{ name, task_len }));
            } else if (task.input) |in| {
                for (in, 0..) |T, i| if (T != o_task.input.?[i]) {
                    const message = "Override '{s}' input #{d} expects type {s}";
                    @compileError(std.fmt.comptimePrint(message, .{ name, i, @typeName(T) }));
                };
            }
        }

        self.map.append(.{
            .task = task,
            .evaluator = OpaqueEvaluator.of(o_task),
        }) catch @compileError("Overflow");
        return o_task;
    }

    pub fn consume(comptime self: *TasksOverrider) Invoker {
        const map = self.pack();
        return .{ .overrides = struct {
            fn provide(tag: ComptimeTag) ?OpaqueEvaluator {
                inline for (map) |item| {
                    const actual = ComptimeTag.of(item.task);
                    if (actual == tag) return item.evaluator;
                }
                return null;
            }
        }.provide };
    }

    fn pack(comptime self: *TasksOverrider) []const Mapping {
        const len = self.map.len;
        const static: [len]Mapping = self.map.slice()[0..len].*;
        return &static;
    }
};

test "TasksOverrider" {
    const invoker, const AltTask = comptime blk: {
        var overrider: TasksOverrider = .{};

        const AltTask = overrider.override(tests.NoOpHook, "Alt NoOp", struct {
            pub fn f(_: *const Delegate, _: bool) void {}
        }.f, .{});

        break :blk .{ overrider.consume(), AltTask };
    };

    try testing.expectEqual(false, invoker.hasOverride(tests.Call));
    try testing.expectEqual(true, invoker.hasOverride(tests.NoOpHook));

    var recorder = InvokeTracerRecorder.init(test_alloc);
    defer recorder.deinit();

    invoker.evaluateSync(tests.NoOpHook, recorder.tracer(), &tsk.NOOP_DELEGATE, .{true});
    try recorder.expectInvoke(0, .sync, AltTask);

    recorder.clear();
    var buffer: [32]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const invocation = try invoker.prepareAsync(fixed.allocator(), tests.NoOpHook, .{true});
    try invocation.evaluate(recorder.tracer(), &tsk.NOOP_DELEGATE);
    try recorder.expectInvoke(0, .asyncd, AltTask);
}
