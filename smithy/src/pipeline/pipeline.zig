const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const ivk = @import("invoke.zig");
const Task = @import("task.zig").Task;
const Scope = @import("scope.zig").Scope;
const scd = @import("schedule.zig");
const Schedule = scd.Schedule;
const ScheduleResources = scd.ScheduleResources;
const util = @import("utils.zig");

pub const Pipeline = struct {
    scope: *Scope,
    schedule: Schedule,
    resources: ScheduleResources,

    pub const Options = struct {
        tracer: ?ivk.InvokeTracer = null,
        invoker: ?ivk.Invoker = null,
    };

    pub fn init(allocator: Allocator, options: Options) !*Pipeline {
        const self = try allocator.create(Pipeline);
        errdefer allocator.destroy(self);

        self.resources = ScheduleResources.init(allocator);
        errdefer self.resources.deinit();

        const scope = try self.resources.retainScope();
        errdefer self.resources.releaseScope(scope);
        scope.parent = null;
        if (options.invoker) |invoker| scope.invoker = invoker;
        self.scope = scope;

        self.schedule = Schedule.init(allocator, &self.resources, scope, .{});
        if (options.tracer) |t| self.schedule.tracer = t;

        return self;
    }

    pub fn deinit(self: *Pipeline) void {
        const alloc = self.resources.allocator;

        self.schedule.deinit();

        self.resources.releaseScope(self.scope);
        self.resources.deinit();

        alloc.destroy(self);
    }

    pub fn evaluateSync(self: *Pipeline, comptime task: Task, input: task.In) !task.Payload() {
        return self.schedule.evaluateSync(null, task, input);
    }

    pub fn scheduleAsync(self: *Pipeline, comptime task: Task, input: task.In) !void {
        try self.schedule.appendAsync(null, task, input);
    }

    pub fn scheduleCallback(
        self: *Pipeline,
        comptime task: Task,
        input: task.In,
        callbackCtx: *const anyopaque,
        callbackFn: Task.Callback(task),
    ) !void {
        try self.schedule.appendCallback(null, task, input, callbackCtx, callbackFn);
    }

    pub fn run(self: *Pipeline) !void {
        try self.schedule.evaluate();
    }
};

pub const PipelineTesterOptions = struct {
    invoker: ?ivk.Invoker = null,
};

pub const PipelineTester = struct {
    pipeline: *Pipeline,
    root_scope: *Scope,
    recorder: *ivk.InvokeTraceRecorder,

    pub fn init(options: PipelineTesterOptions) !PipelineTester {
        const recorder = try test_alloc.create(ivk.InvokeTraceRecorder);
        recorder.* = ivk.InvokeTraceRecorder.init(test_alloc);
        errdefer test_alloc.destroy(recorder);

        const pipeline = try Pipeline.init(test_alloc, .{
            .tracer = recorder.tracer(),
            .invoker = options.invoker,
        });
        errdefer test_alloc.destroy(pipeline);

        return .{
            .pipeline = pipeline,
            .root_scope = pipeline.scope,
            .recorder = recorder,
        };
    }

    pub fn deinit(self: *PipelineTester) void {
        self.pipeline.deinit();
        self.recorder.deinit();
        test_alloc.destroy(self.recorder);
    }

    pub fn reset(self: *PipelineTester) void {
        self.resetScope();
        self.resetRecorder();
    }

    pub fn resetScope(self: *PipelineTester) void {
        self.root_scope.reset();
    }

    pub fn resetRecorder(self: *PipelineTester) void {
        self.recorder.clear();
    }

    //
    // Schedule
    //

    pub fn evaluateSync(self: *PipelineTester, comptime task: Task, input: task.In) !task.Payload() {
        return self.pipeline.evaluateSync(task, input);
    }

    pub inline fn expectEvaluateSyncError(
        self: *PipelineTester,
        expected: anyerror,
        comptime task: Task,
        input: task.In,
    ) !void {
        const output = self.pipeline.evaluateSync(task, input);
        try testing.expectError(expected, output);
    }

    pub fn scheduleAsync(self: *PipelineTester, comptime task: Task, input: task.In) !void {
        try self.pipeline.scheduleAsync(task, input);
    }

    pub fn scheduleCallback(
        self: *PipelineTester,
        comptime task: Task,
        input: task.In,
        callbackCtx: *const anyopaque,
        callbackFn: Task.Callback(task),
    ) !void {
        try self.pipeline.scheduleCallback(task, input, callbackCtx, callbackFn);
    }

    pub fn run(self: *PipelineTester) !void {
        try self.pipeline.run();
    }

    pub inline fn expectRunError(self: *PipelineTester, expected: anyerror) !void {
        try testing.expectError(expected, self.pipeline.run());
    }

    pub fn expectDidInvoke(
        self: PipelineTester,
        order: usize,
        method: ivk.InvokeMethod,
        comptime task: Task,
    ) !void {
        self.recorder.expectInvoke(order, method, task);
    }

    pub fn expectDidCallback(
        self: PipelineTester,
        order: usize,
        callback: *const anyopaque,
        context: ?*const anyopaque,
    ) !void {
        self.recorder.expectCallback(order, callback, context);
    }

    //
    // Scope
    //

    pub fn provideService(
        self: *PipelineTester,
        service: anytype,
        comptime cleanup: ?*const fn (ctx: util.Reference(@TypeOf(service)), allocator: Allocator) void,
    ) !util.Reference(@TypeOf(service)) {
        return self.root_scope.provideService(service, cleanup);
    }

    pub fn defineValue(self: *PipelineTester, comptime T: type, comptime tag: anytype, value: T) !void {
        try self.root_scope.defineValue(T, tag, value);
    }

    pub fn writeValue(self: *PipelineTester, comptime T: type, comptime tag: anytype, value: T) !void {
        try self.root_scope.writeValue(T, tag, value);
    }

    pub fn expectScopeValue(self: PipelineTester, comptime T: type, comptime tag: anytype, expected: T) !void {
        const actual = self.root_scope.readValue(usize, tag);
        try testing.expectEqualDeep(expected, actual);
    }
};
