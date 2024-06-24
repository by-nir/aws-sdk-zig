const std = @import("std");
const ZigType = std.builtin.Type;
const testing = std.testing;

pub const Task = struct {
    name: []const u8,
    input: ?[]const type,
    output: type,
    func: *const anyopaque,
    Fn: type,

    pub const DefineOptions = struct {};

    pub fn define(name: []const u8, comptime options: DefineOptions, comptime func: anytype) Task {
        _ = options;

        const meta: ZigType.Fn = switch (@typeInfo(@TypeOf(func))) {
            .Fn => |t| t,
            .Pointer => |t| blk: {
                const target = @typeInfo(t.child);
                if (t.size == .One and target == .Fn)
                    break :blk target.Fn
                else
                    @compileError("Task function must be a function");
            },
            else => @compileError("Task function must be a function"),
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
        .func = test_tasks.noOp,
        .Fn = *const @TypeOf(test_tasks.noOp),
    }, test_tasks.NoOp);

    try testing.expectEqualDeep(Task{
        .name = "Crash",
        .input = null,
        .output = error{Fail}!void,
        .func = test_tasks.crash,
        .Fn = *const @TypeOf(test_tasks.crash),
    }, test_tasks.Crash);

    comptime try testing.expectEqualDeep(Task{
        .name = "Multiply",
        .input = &.{ usize, usize },
        .output = usize,
        .func = test_tasks.multiply,
        .Fn = *const @TypeOf(test_tasks.multiply),
    }, test_tasks.Multiply);
}

test "Task.invoke" {
    test_tasks.did_call = false;
    test_tasks.Call.invoke(.{}, .{});
    try testing.expect(test_tasks.did_call);

    try testing.expectEqual(108, test_tasks.Multiply.invoke(.{}, .{ 2, 54 }));
}

pub const TaskDelegate = struct {};

pub const TaskTest = struct {
    delegate: TaskDelegate,

    pub fn init(delegate: TaskDelegate) TaskTest {
        return .{ .delegate = delegate };
    }

    pub fn invoke(self: TaskTest, comptime task: Task, input: task.In(false)) task.Out(.retain) {
        self.cleanup();
        return task.invoke(self.delegate, input);
    }

    pub fn expectEqual(
        self: TaskTest,
        comptime task: Task,
        expected: task.Out(.strip),
        input: task.In(false),
    ) !void {
        self.cleanup();
        const value = task.invoke(self.delegate, input);
        try testing.expectEqual(expected, if (@typeInfo(task.output) == .ErrorUnion) try value else value);
    }

    pub fn expectError(
        self: TaskTest,
        comptime task: Task,
        expected: anyerror,
        input: task.In(false),
    ) !void {
        self.cleanup();
        const value = task.invoke(self.delegate, input);
        try testing.expectError(expected, value);
    }

    fn cleanup(self: TaskTest) void {
        _ = self; // autofix
    }
};

test "TaskTest" {
    const tester = TaskTest.init(.{});

    test_tasks.did_call = false;
    tester.invoke(test_tasks.Call, .{});
    try testing.expect(test_tasks.did_call);

    try tester.expectEqual(test_tasks.Multiply, 108, .{ 2, 54 });

    try tester.invoke(test_tasks.Failable, .{false});
    try tester.expectError(test_tasks.Failable, error.Fail, .{true});
}

const test_tasks = struct {
    const NoOp = Task.define("No Op", .{}, noOp);
    fn noOp(_: TaskDelegate) void {}

    var did_call: bool = false;
    const Call = Task.define("Call", .{}, call);
    fn call(_: TaskDelegate) void {
        did_call = true;
    }

    const Crash = Task.define("Crash", .{}, crash);
    fn crash(_: TaskDelegate) error{Fail}!void {
        return error.Fail;
    }

    const Failable = Task.define("Failable", .{}, failable);
    fn failable(_: TaskDelegate, fail: bool) error{Fail}!void {
        if (fail) return error.Fail;
    }

    const Multiply = Task.define("Multiply", .{}, multiply);
    fn multiply(_: TaskDelegate, a: usize, b: usize) usize {
        return a * b;
    }
};
