const std = @import("std");
const ZigType = std.builtin.Type;
const testing = std.testing;
const schdl = @import("schedule.zig");

pub fn TaskCallback(comptime task: Task) type {
    return if (task.Out(.retain) == void)
        *const fn (ctx: *const anyopaque) anyerror!void
    else
        *const fn (ctx: *const anyopaque, output: task.Out(.retain)) anyerror!void;
}

pub const Task = struct {
    name: []const u8,
    input: ?[]const type,
    output: type,
    func: *const anyopaque,
    Fn: type,

    pub const DefineOptions = struct {};

    pub fn define(name: []const u8, comptime func: anytype, comptime options: DefineOptions) Task {
        _ = options;

        const meta: ZigType.Fn = switch (@typeInfo(@TypeOf(func))) {
            .Fn => |t| t,
            .Pointer => |t| blk: {
                const target = @typeInfo(t.child);
                if (t.size != .One or target != .Fn) @compileError("Task `func` must be a function type");
                break :blk target.Fn;
            },
            else => @compileError("Task `func` must be a function type"),
        };

        const len = meta.params.len;
        if (len == 0 or meta.params[0].type != TaskDelegate) {
            @compileError("Task '" ++ name ++ "' first parameter must be `TaskDelegate`");
        }

        comptime var input_mut: [len - 1]type = undefined;
        for (1..len) |i| {
            input_mut[i - 1] = meta.params[i].type.?;
        }
        const input = input_mut;

        return .{
            .name = name,
            .input = if (len > 1) &input else null,
            .output = meta.return_type.?,
            .func = func,
            .Fn = *const @Type(.{ .Fn = meta }),
        };
    }

    pub fn invoke(comptime self: Task, delegate: TaskDelegate, input: self.In(false)) self.Out(.retain) {
        const args = if (self.input) |types| blk: {
            var values: self.In(true) = undefined;
            values.@"0" = delegate;
            inline for (0..types.len) |i| {
                @field(values, std.fmt.comptimePrint("{d}", .{i + 1})) = input[i];
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

    pub fn In(comptime self: Task, comptime with_delegate: bool) type {
        const input = self.input orelse if (with_delegate) {
            return @TypeOf(.{TaskDelegate});
        } else {
            return @TypeOf(.{});
        };

        const len = if (with_delegate) input.len + 1 else input.len;
        var fields: [len]ZigType.StructField = undefined;
        if (with_delegate) {
            fields[0] = .{
                .name = "0",
                .type = TaskDelegate,
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(TaskDelegate),
            };
        }

        const start_i = if (with_delegate) 1 else 0;
        for (input, start_i..) |T, i| {
            fields[i] = .{
                .name = std.fmt.comptimePrint("{d}", .{i}),
                .type = T,
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(T),
            };
        }

        return @Type(ZigType{ .Struct = .{
            .is_tuple = true,
            .layout = .auto,
            .fields = &fields,
            .decls = &.{},
        } });
    }
};

test "Task.define" {
    try testing.expectEqualDeep(Task{
        .name = "No Op",
        .input = null,
        .output = void,
        .func = tests.noOp,
        .Fn = *const @TypeOf(tests.noOp),
    }, tests.NoOp);

    try testing.expectEqualDeep(Task{
        .name = "Crash",
        .input = null,
        .output = error{Fail}!void,
        .func = tests.crash,
        .Fn = *const @TypeOf(tests.crash),
    }, tests.Crash);

    comptime try testing.expectEqualDeep(Task{
        .name = "Multiply",
        .input = &.{ usize, usize },
        .output = usize,
        .func = tests.multiply,
        .Fn = *const @TypeOf(tests.multiply),
    }, tests.Multiply);
}

test "Task.invoke" {
    tests.did_call = false;
    tests.Call.invoke(NOOP_DELEGATE, .{});
    try testing.expect(tests.did_call);

    const value = tests.Multiply.invoke(NOOP_DELEGATE, .{ 2, 54 });
    try testing.expectEqual(108, value);
}

pub const TaskTester = struct {
    delegate: TaskDelegate,

    pub fn init(delegate: TaskDelegate) TaskTester {
        return .{ .delegate = delegate };
    }

    pub fn invoke(self: TaskTester, comptime task: Task, input: task.In(false)) task.Out(.retain) {
        self.cleanup();
        return task.invoke(self.delegate, input);
    }

    pub fn expectEqual(
        self: TaskTester,
        comptime task: Task,
        expected: task.Out(.strip),
        input: task.In(false),
    ) !void {
        self.cleanup();
        const value = task.invoke(self.delegate, input);
        try testing.expectEqual(expected, if (@typeInfo(task.output) == .ErrorUnion) try value else value);
    }

    pub fn expectError(
        self: TaskTester,
        comptime task: Task,
        expected: anyerror,
        input: task.In(false),
    ) !void {
        self.cleanup();
        const value = task.invoke(self.delegate, input);
        try testing.expectError(expected, value);
    }

    fn cleanup(self: TaskTester) void {
        _ = self; // autofix
    }
};

test "TaskTester" {
    const tester = TaskTester.init(NOOP_DELEGATE);

    tests.did_call = false;
    tester.invoke(tests.Call, .{});
    try testing.expect(tests.did_call);

    try tester.expectEqual(tests.Multiply, 108, .{ 2, 54 });

    try tester.invoke(tests.Failable, .{false});
    try tester.expectError(tests.Failable, error.Fail, .{true});
}

pub const tests = struct {
    pub const NoOp = Task.define("No Op", noOp, .{});
    pub fn noOp(_: TaskDelegate) void {}

    pub var did_call: bool = false;
    pub const Call = Task.define("Call", call, .{});
    fn call(_: TaskDelegate) void {
        did_call = true;
    }

    pub const Crash = Task.define("Crash", crash, .{});
    fn crash(_: TaskDelegate) error{Fail}!void {
        return error.Fail;
    }

    pub const Failable = Task.define("Failable", failable, .{});
    fn failable(_: TaskDelegate, fail: bool) error{Fail}!void {
        if (fail) return error.Fail;
    }

    pub const Multiply = Task.define("Multiply", multiply, .{});
    fn multiply(_: TaskDelegate, a: usize, b: usize) usize {
        return a * b;
    }
};

const NOOP_DELEGATE = TaskDelegate{
    .scheduler = undefined,
};

pub const TaskDelegate = struct {
    node: *schdl.ScheduleNode,
    scheduler: *schdl.Schedule,

    pub fn invokeSync(self: TaskDelegate, comptime task: Task, input: task.In(false)) !task.Out(.strip) {
        return self.scheduler.invokeSync(task, input);
    }

    pub fn invokeAsync(self: TaskDelegate, comptime task: Task, input: task.In(false)) !void {
        try self.scheduler.invokeAsync(self.node, task, input);
    }

    pub fn invokeCallback(
        self: TaskDelegate,
        comptime task: Task,
        input: task.In(false),
        context: *const anyopaque,
        callback: TaskCallback(task),
    ) !void {
        try self.scheduler.invokeCallback(self.node, task, input, context, callback);
    }
};
