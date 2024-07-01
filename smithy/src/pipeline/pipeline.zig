const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const ivk = @import("invoke.zig");
const scd = @import("schedule.zig");
const Scope = @import("scope.zig").Scope;
const tsk = @import("task.zig");
const Task = tsk.Task;
const Delegate = tsk.Delegate;
const ComptimeTag = @import("utils.zig").ComptimeTag;
const tests = @import("tests.zig");

pub const Pipeline = struct {
    scope: *Scope,
    schedule: scd.Schedule,
    resources: scd.ScheduleResources,

    pub const Options = struct {
        tracer: ?ivk.InvokeTracer = null,
        overrides: ?ivk.InvokeOverrideFn = null,
    };

    pub fn init(allocator: Allocator, options: Options) !*Pipeline {
        const self = try allocator.create(Pipeline);
        errdefer allocator.destroy(self);

        self.resources = scd.ScheduleResources.init(allocator);
        errdefer self.resources.deinit();

        const scope = try self.resources.retainScope();
        errdefer self.resources.releaseScope(scope);
        scope.parent = null;
        if (options.overrides) |t| scope.invoker = .{ .overrides = t };
        self.scope = scope;

        self.schedule = scd.Schedule.init(allocator, &self.resources, scope);
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

    pub fn evaluateSync(self: *Pipeline, comptime task: Task, input: task.In(false)) !task.Out(.strip) {
        return self.schedule.evaluateSync(null, task, input);
    }

    pub fn scheduleAsync(self: *Pipeline, comptime task: Task, input: task.In(false)) !void {
        try self.schedule.appendAsync(null, task, input);
    }

    pub fn scheduleCallback(
        self: *Pipeline,
        comptime task: Task,
        input: task.In(false),
        callbackCtx: *const anyopaque,
        callbackFn: Task.Callback(task),
    ) !void {
        try self.schedule.appendCallback(null, task, input, callbackCtx, callbackFn);
    }

    pub fn run(self: *Pipeline) !void {
        try self.schedule.evaluate();
    }
};

pub const TasksOverrider = struct {
    comptime len: usize = 0,
    comptime map: [128]Mapping = undefined,

    const Mapping = struct {
        task: Task,
        evaluator: ivk.OpaqueEvaluator,
    };

    pub fn override(
        comptime self: *TasksOverrider,
        comptime task: Task,
        comptime name: []const u8,
        comptime func: anytype,
        comptime options: Task.Options,
    ) void {
        const ovrd = Task.define("[OVERRIDE] " ++ name, func, options);
        if (ovrd.output != task.output) {
            @compileError("Override '" ++ name ++ "' expects output type " ++ @typeName(task.output));
        } else if (task.input != null or ovrd.input != null) {
            const task_len = if (task.input) |in| in.len else 0;
            const ovrd_len = if (ovrd.input) |in| in.len else 0;
            if (task_len != ovrd_len) {
                const message = "Override '{s}' expects {d} input parameters";
                @compileError(std.fmt.comptimePrint(message, .{ name, task_len }));
            } else if (task.input) |in| {
                for (in, 0..) |T, i| if (T != ovrd.input.?[i]) {
                    const message = "Override '{s}' input #{d} expects type {s}";
                    @compileError(std.fmt.comptimePrint(message, .{ name, i, @typeName(T) }));
                };
            }
        }

        self.map[self.len] = .{
            .task = task,
            .evaluator = ivk.OpaqueEvaluator.of(ovrd),
        };
        self.len += 1;
    }

    pub fn consume(comptime self: *TasksOverrider) ivk.InvokeOverrideFn {
        const map = self.pack();
        return struct {
            fn provide(tag: ComptimeTag) ?ivk.OpaqueEvaluator {
                inline for (map) |item| {
                    const actual = ComptimeTag.of(item.task);
                    if (actual == tag) return item.evaluator;
                }
                return null;
            }
        }.provide;
    }

    fn pack(comptime self: *TasksOverrider) []const Mapping {
        const static: [self.len]Mapping = self.map[0..self.len].*;
        return &static;
    }
};

test "TasksOverrider" {
    const overrides = comptime blk: {
        var overrider: TasksOverrider = .{};
        overrider.override(tests.NoOpHook, "Alt NoOp", struct {
            pub fn f(_: *const Delegate, _: bool) void {}
        }.f, .{});
        break :blk overrider.consume();
    };

    const tracer = ivk.TracerTester;

    const pipeline = try Pipeline.init(test_alloc, .{
        .tracer = tracer.shared,
        .overrides = overrides,
    });
    defer pipeline.deinit();

    const invoker = pipeline.scope.invoker;
    try testing.expectEqual(false, invoker.hasOverride(tests.Call));
    try testing.expectEqual(true, invoker.hasOverride(tests.NoOpHook));

    tracer.reset();
    try pipeline.evaluateSync(tests.NoOpHook, .{true});
    try testing.expectEqual(.sync, tracer.last_method);
    try testing.expect(ComptimeTag.of(tests.NoOpHook) != tracer.last_invoke);

    tracer.reset();
    try pipeline.scheduleAsync(tests.NoOpHook, .{true});
    try pipeline.run();
    try pipeline.scheduleAsync(tests.NoOpHook, .{true});
    try testing.expectEqual(.asyncd, tracer.last_method);
    try testing.expect(ComptimeTag.of(tests.NoOpHook) != tracer.last_invoke);
}
