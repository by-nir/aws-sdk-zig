const std = @import("std");
const testing = std.testing;
const ZigType = std.builtin.Type;
const Allocator = std.mem.Allocator;
const scp = @import("scope.zig");
const util = @import("utils.zig");
const scd = @import("schedule.zig");
const tests = @import("tests.zig");

pub const Task = struct {
    name: []const u8,
    input: ?[]const type,
    inject: ?[]const type,
    output: type,
    func: *const anyopaque,
    Fn: type,

    pub const Options = struct {
        inject: ?[]const type = null,
    };

    pub fn define(name: []const u8, comptime func: anytype, comptime options: Options) Task {
        const meta: ZigType.Fn = switch (@typeInfo(@TypeOf(func))) {
            .Fn => |t| t,
            .Pointer => |t| blk: {
                const target = @typeInfo(t.child);
                if (t.size != .One or target != .Fn) @compileError("Task '" ++ name ++ "' expects a function type");
                break :blk target.Fn;
            },
            else => @compileError("Task '" ++ name ++ "' expects a function type"),
        };

        const len = meta.params.len;
        if (len == 0 or meta.params[0].type != *const Delegate) {
            @compileError("Task '" ++ name ++ "' first parameter must be `*const Delegate`");
        }

        const inject_len = comptime if (options.inject) |inj| inj.len else 0;
        const inject = comptime if (options.inject) |inj| blk: {
            std.debug.assert(inject_len > 0);
            var types: [inject_len]type = undefined;
            for (0..inj.len) |i| {
                const T = inj[i];
                switch (@typeInfo(T)) {
                    .Struct => {},
                    .Pointer, .Optional => @compileError(std.fmt.comptimePrint(
                        "Task '{s}' options.inject[{d}] expects a plain struct type, without modifiers",
                        .{ name, i },
                    )),
                    else => if (@typeInfo(T) != .Struct) @compileError(std.fmt.comptimePrint(
                        "Task '{s}' options.inject[{d}] expects a struct type",
                        .{ name, i },
                    )),
                }

                var is_optional = false;
                var Param = meta.params[i + 1].type.?;
                if (@typeInfo(Param) == .Optional) {
                    is_optional = true;
                    Param = @typeInfo(Param).Optional.child;
                }

                if (Param != *T) @compileError(std.fmt.comptimePrint(
                    if (is_optional)
                        "Task '{s}' parameter #{d} expects type ?*{s}"
                    else
                        "Task '{s}' parameter #{d} expects type *{s}",
                    .{ name, i + 1, @typeName(T) },
                ));

                types[i] = if (is_optional) ?*T else *T;
            }
            const static = types;
            break :blk &static;
        } else null;

        const input_len = len - inject_len - 1;
        const input = comptime if (input_len > 0) blk: {
            var types: [input_len]type = undefined;
            for (0..input_len) |i| {
                types[i] = meta.params[i + 1 + inject_len].type.?;
            }
            const static = types;
            break :blk &static;
        } else null;

        return .{
            .name = name,
            .inject = inject,
            .input = input,
            .output = meta.return_type.?,
            .func = func,
            .Fn = *const @Type(.{ .Fn = meta }),
        };
    }

    /// A special unimplemented-task, used as a placeholder that may be overridden by the pipeline.
    pub fn hook(name: []const u8, comptime input: ?[]const type, comptime Output: type) Task {
        return .{
            .name = name,
            .inject = null,
            .input = if (input) |in| (if (in.len > 0) in else null) else input,
            .output = Output,
            .func = undefined,
            .Fn = @TypeOf(.hook_unimplemented),
        };
    }

    pub fn evaluate(comptime self: Task, delegate: *const Delegate, input: self.In(false)) self.Out(.retain) {
        if (comptime self.Fn == @TypeOf(.hook_unimplemented)) {
            const message = "Hook '{s}' is not implemented";
            if (std.debug.runtime_safety) {
                std.log.err(message, .{self.name});
                unreachable;
            } else {
                std.debug.panic(message, .{self.name});
            }
            return;
        }

        const args = if (self.input) |types| blk: {
            var values: self.In(true) = undefined;
            values.@"0" = delegate;

            comptime var shift: usize = 1;
            if (self.inject) |inj| inline for (inj) |T| {
                const Ref = switch (@typeInfo(T)) {
                    .Optional => |t| t.child,
                    else => T,
                };
                const optional = T != Ref;
                const value = delegate.scope.getService(Ref) orelse if (optional) null else {
                    const message = "Task '{s}' requires injectable service `{s}`";
                    if (std.debug.runtime_safety)
                        std.log.err(message, .{ self.name, @typeName(T) })
                    else
                        std.debug.panic(message, .{ self.name, @typeName(T) });
                    unreachable;
                };
                @field(values, std.fmt.comptimePrint("{d}", .{shift})) = value;
                shift += 1;
            };

            inline for (0..types.len) |i| {
                @field(values, std.fmt.comptimePrint("{d}", .{i + shift})) = input[i];
            }
            break :blk values;
        } else .{delegate};

        const func = @as(self.Fn, @alignCast(@ptrCast(self.func)));
        return @call(.auto, func, args);
    }

    pub const ModifyError = union(enum) { retain, strip, expand: anyerror };

    pub fn Out(comptime self: Task, err: ModifyError) type {
        switch (err) {
            .retain => return self.output,
            .strip => return switch (@typeInfo(self.output)) {
                .ErrorUnion => |t| t.payload,
                else => self.output,
            },
            .expand => |E| return switch (@typeInfo(self.output)) {
                .ErrorUnion => |t| t.payload,
                else => E!self.output,
            },
        }
    }

    pub fn In(comptime self: Task, comptime with_inject: bool) type {
        const input_len = if (self.input) |t| t.len else 0;
        const inject_len = if (self.inject) |t| t.len else 0;
        if (input_len + inject_len == 0) {
            return if (with_inject) struct { *const Delegate } else return @TypeOf(.{});
        }

        var shift: usize = 0;
        const len = if (with_inject) 1 + inject_len + input_len else input_len;
        var fields: [len]ZigType.StructField = undefined;

        if (with_inject) {
            shift = 1;
            fields[0] = .{
                .name = "0",
                .type = *const Delegate,
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(*const Delegate),
            };

            if (self.inject) |in| for (in) |T| {
                fields[shift] = .{
                    .name = std.fmt.comptimePrint("{d}", .{shift}),
                    .type = T,
                    .default_value = null,
                    .is_comptime = false,
                    .alignment = @alignOf(T),
                };
                shift += 1;
            };
        }

        if (self.input) |in| for (in, shift..) |T, i| {
            fields[i] = .{
                .name = std.fmt.comptimePrint("{d}", .{i}),
                .type = T,
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(T),
            };
        };

        return @Type(ZigType{ .Struct = .{
            .is_tuple = true,
            .layout = .auto,
            .fields = &fields,
            .decls = &.{},
        } });
    }

    pub fn Callback(comptime task: Task) type {
        return if (task.Out(.retain) == void)
            *const fn (ctx: *const anyopaque) anyerror!void
        else
            *const fn (ctx: *const anyopaque, output: task.Out(.retain)) anyerror!void;
    }
};

pub const NOOP_DELEGATE = Delegate{
    .children = .{},
    .scope = undefined,
    .scheduler = undefined,
};

pub const Delegate = struct {
    scope: *scp.Scope,
    scheduler: *scd.Schedule,
    children: scd.ScheduleQueue,
    branchScope: ?*const fn (Delegate: *const Delegate) anyerror!void = null,

    pub fn evaluate(self: *const Delegate, comptime task: Task, input: task.In(false)) !task.Out(.strip) {
        return self.scheduler.evaluateSync(self, task, input);
    }

    pub fn schedule(self: *const Delegate, comptime task: Task, input: task.In(false)) !void {
        if (task.Out(.strip) != void)
            @compileError("Task '" ++ task.name ++ "' returns a value, use `scheduleCallback` instead.");

        try self.scheduler.appendAsync(self, task, input);
    }

    pub fn scheduleCallback(
        self: *const Delegate,
        comptime task: Task,
        input: task.In(false),
        context: *const anyopaque,
        callback: Task.Callback(task),
    ) !void {
        try self.scheduler.appendCallback(self, task, input, context, callback);
    }

    pub fn hasOverride(self: Delegate, comptime task: Task) bool {
        return self.scope.invoker.hasOverride(task);
    }

    pub fn provide(
        self: *const Delegate,
        value: anytype,
        comptime cleanup: ?*const fn (ctx: util.Reference(@TypeOf(value)), allocator: Allocator) void,
    ) !util.Reference(@TypeOf(value)) {
        if (self.branchScope) |branch| try branch(self);
        return self.scope.provideService(value, cleanup);
    }

    pub fn defineValue(self: *const Delegate, comptime T: type, comptime tag: anytype, value: T) !void {
        if (self.branchScope) |branch| try branch(self);
        try self.scope.defineValue(T, tag, value);
    }

    pub fn writeValue(self: Delegate, comptime T: type, comptime tag: anytype, value: T) !void {
        try self.scope.writeValue(T, tag, value);
    }

    pub fn readValue(self: Delegate, comptime T: type, comptime tag: anytype) util.Optional(T) {
        return self.scope.readValue(T, tag);
    }

    pub fn hasValue(self: Delegate, comptime tag: anytype) bool {
        return self.scope.hasValue(tag);
    }
};

test "Task.define" {
    try testing.expectEqualDeep(Task{
        .name = "NoOp",
        .inject = null,
        .input = null,
        .output = void,
        .func = tests.noOpFn,
        .Fn = *const @TypeOf(tests.noOpFn),
    }, tests.NoOp);

    try testing.expectEqualDeep(Task{
        .name = "Crash",
        .inject = null,
        .input = null,
        .output = error{Fail}!void,
        .func = tests.crashFn,
        .Fn = *const @TypeOf(tests.crashFn),
    }, tests.Crash);

    comptime try testing.expectEqualDeep(Task{
        .name = "Multiply",
        .inject = null,
        .input = &.{ usize, usize },
        .output = usize,
        .func = tests.multiplyFn,
        .Fn = *const @TypeOf(tests.multiplyFn),
    }, tests.Multiply);

    comptime try testing.expectEqualDeep(Task{
        .name = "InjectMultiply",
        .inject = &.{*tests.Service},
        .input = &.{usize},
        .output = usize,
        .func = tests.injectMultiplyFn,
        .Fn = *const @TypeOf(tests.injectMultiplyFn),
    }, tests.InjectMultiply);

    comptime try testing.expectEqualDeep(Task{
        .name = "OptInjectMultiply",
        .inject = &.{?*tests.Service},
        .input = &.{usize},
        .output = usize,
        .func = tests.optInjectMultiplyFn,
        .Fn = *const @TypeOf(tests.optInjectMultiplyFn),
    }, tests.OptInjectMultiply);

    try testing.expectEqual("NoOp Hook", tests.NoOpHook.name);
    try testing.expectEqual(null, tests.NoOpHook.inject);
    comptime try testing.expectEqual(&.{bool}, tests.NoOpHook.input);
    try testing.expectEqual(void, tests.NoOpHook.output);
}

test "Task.evaluate" {
    tests.did_call = false;
    tests.Call.evaluate(&NOOP_DELEGATE, .{});
    try testing.expect(tests.did_call);

    const value = tests.Multiply.evaluate(&NOOP_DELEGATE, .{ 2, 54 });
    try testing.expectEqual(108, value);
}

pub const TaskTester = struct {
    delegate: Delegate,

    pub fn init(delegate: Delegate) TaskTester {
        return .{ .delegate = delegate };
    }

    pub fn evaluate(self: TaskTester, comptime task: Task, input: task.In(false)) task.Out(.retain) {
        self.cleanup();
        return task.evaluate(&self.delegate, input);
    }

    pub fn expectEqual(
        self: TaskTester,
        comptime task: Task,
        expected: task.Out(.strip),
        input: task.In(false),
    ) !void {
        self.cleanup();
        const value = task.evaluate(&self.delegate, input);
        try testing.expectEqualDeep(expected, if (@typeInfo(task.output) == .ErrorUnion) try value else value);
    }

    pub fn expectError(
        self: TaskTester,
        comptime task: Task,
        expected: anyerror,
        input: task.In(false),
    ) !void {
        self.cleanup();
        const value = task.evaluate(&self.delegate, input);
        try testing.expectError(expected, value);
    }

    fn cleanup(self: TaskTester) void {
        _ = self; // autofix
    }
};

test "TaskTester" {
    const tester = TaskTester.init(NOOP_DELEGATE);

    tests.did_call = false;
    tester.evaluate(tests.Call, .{});
    try testing.expect(tests.did_call);

    try tester.expectEqual(tests.Multiply, 108, .{ 2, 54 });

    try tester.evaluate(tests.Failable, .{false});
    try tester.expectError(tests.Failable, error.Fail, .{true});
}
