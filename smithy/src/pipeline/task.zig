const std = @import("std");
const ZigType = std.builtin.Type;
const testing = std.testing;

pub const SkipTask = error.TaskPolicySkip;

const ModifyError = union(enum) {
    retain,
    strip,
    expand: anyerror,
};

pub const Task = struct {
    name: []const u8,
    input: ?[]const type,
    output: type,
    func: *const anyopaque,

    pub fn invoke(comptime self: Task, delegate: TaskDelegate, input: self.In(false)) self.Out(.retain) {
        const args = if (self.input) |types| blk: {
            var values: self.In(true) = undefined;
            values.@"0" = delegate;
            inline for (0..types.len) |i| {
                @field(values, std.fmt.comptimePrint("{d}", .{i + 1})) = input[i];
            }
            break :blk values;
        } else .{delegate};

        const func = @as(self.Func(), @alignCast(@ptrCast(self.func)));
        return @call(.auto, func, args);
    }

    pub fn Func(comptime self: Task) type {
        const input = self.input orelse {
            return *const fn (task: TaskDelegate) self.Out(.retain);
        };

        var params: [1 + input.len]ZigType.Fn.Param = undefined;
        params[0] = .{
            .is_generic = false,
            .is_noalias = false,
            .type = TaskDelegate,
        };
        for (input, 1..) |T, i| {
            params[i] = .{
                .is_generic = false,
                .is_noalias = false,
                .type = T,
            };
        }

        return *const @Type(ZigType{ .Fn = .{
            .is_generic = false,
            .is_var_args = false,
            .calling_convention = .Unspecified,
            .return_type = self.Out(.retain),
            .params = &params,
        } });
    }

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

test {
    const tasks = struct {
        pub var did_call: bool = false;

        pub const Call = Task{
            .name = "Call",
            .func = call,
            .input = null,
            .output = void,
        };

        fn call(_: TaskDelegate) void {
            did_call = true;
        }

        pub const Multiply = Task{
            .name = "Multiply",
            .func = multiply,
            .input = &.{ usize, usize },
            .output = usize,
        };

        fn multiply(_: TaskDelegate, a: usize, b: usize) usize {
            return a * b;
        }

        pub const Failable = Task{
            .name = "Failable",
            .func = failable,
            .input = &.{bool},
            .output = anyerror!void,
        };

        fn failable(_: TaskDelegate, fail: bool) !void {
            if (fail) return error.Fail;
        }
    };

    const tester = TaskTest.init(.{});

    tasks.did_call = false;
    tester.invoke(tasks.Call, .{});
    try testing.expect(tasks.did_call);

    try tester.expectEqual(tasks.Multiply, 108, .{ 2, 54 });

    try tester.invoke(tasks.Failable, .{false});
    try tester.expectError(tasks.Failable, error.Fail, .{true});
}
