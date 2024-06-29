const std = @import("std");
const testing = std.testing;
const ZigType = std.builtin.Type;
const scp = @import("scope.zig");
const Delegate = scp.Delegate;
const Reference = @import("utils.zig").Reference;

pub const Task = struct {
    name: []const u8,
    input: ?[]const type,
    inject: ?[]const type,
    output: type,
    func: *const anyopaque,
    Fn: type,

    pub const DefineOptions = struct {
        inject: ?[]const type = null,
    };

    pub fn define(name: []const u8, comptime func: anytype, comptime options: DefineOptions) Task {
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

    pub fn invoke(comptime self: Task, delegate: *const Delegate, input: self.In(false)) self.Out(.retain) {
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

test "Task.define" {
    try testing.expectEqualDeep(Task{
        .name = "No Op",
        .inject = null,
        .input = null,
        .output = void,
        .func = tests.noOp,
        .Fn = *const @TypeOf(tests.noOp),
    }, tests.NoOp);

    try testing.expectEqualDeep(Task{
        .name = "Crash",
        .inject = null,
        .input = null,
        .output = error{Fail}!void,
        .func = tests.crash,
        .Fn = *const @TypeOf(tests.crash),
    }, tests.Crash);

    comptime try testing.expectEqualDeep(Task{
        .name = "Multiply",
        .inject = null,
        .input = &.{ usize, usize },
        .output = usize,
        .func = tests.multiply,
        .Fn = *const @TypeOf(tests.multiply),
    }, tests.Multiply);

    comptime try testing.expectEqualDeep(Task{
        .name = "InjectMultiply",
        .inject = &.{*tests.Service},
        .input = &.{usize},
        .output = usize,
        .func = tests.injectMultiply,
        .Fn = *const @TypeOf(tests.injectMultiply),
    }, tests.InjectMultiply);

    comptime try testing.expectEqualDeep(Task{
        .name = "OptInjectMultiply",
        .inject = &.{?*tests.Service},
        .input = &.{usize},
        .output = usize,
        .func = tests.optInjectMultiply,
        .Fn = *const @TypeOf(tests.optInjectMultiply),
    }, tests.OptInjectMultiply);
}

test "Task.invoke" {
    tests.did_call = false;
    tests.Call.invoke(&scp.NOOP_DELEGATE, .{});
    try testing.expect(tests.did_call);

    const value = tests.Multiply.invoke(&scp.NOOP_DELEGATE, .{ 2, 54 });
    try testing.expectEqual(108, value);
}

pub const TaskTester = struct {
    delegate: Delegate,

    pub fn init(delegate: Delegate) TaskTester {
        return .{ .delegate = delegate };
    }

    pub fn invoke(self: TaskTester, comptime task: Task, input: task.In(false)) task.Out(.retain) {
        self.cleanup();
        return task.invoke(&self.delegate, input);
    }

    pub fn expectEqual(
        self: TaskTester,
        comptime task: Task,
        expected: task.Out(.strip),
        input: task.In(false),
    ) !void {
        self.cleanup();
        const value = task.invoke(&self.delegate, input);
        try testing.expectEqual(expected, if (@typeInfo(task.output) == .ErrorUnion) try value else value);
    }

    pub fn expectError(
        self: TaskTester,
        comptime task: Task,
        expected: anyerror,
        input: task.In(false),
    ) !void {
        self.cleanup();
        const value = task.invoke(&self.delegate, input);
        try testing.expectError(expected, value);
    }

    fn cleanup(self: TaskTester) void {
        _ = self; // autofix
    }
};

test "TaskTester" {
    const tester = TaskTester.init(scp.NOOP_DELEGATE);

    tests.did_call = false;
    tester.invoke(tests.Call, .{});
    try testing.expect(tests.did_call);

    try tester.expectEqual(tests.Multiply, 108, .{ 2, 54 });

    try tester.invoke(tests.Failable, .{false});
    try tester.expectError(tests.Failable, error.Fail, .{true});
}

pub const tests = struct {
    pub const NoOp = Task.define("No Op", noOp, .{});
    pub fn noOp(_: *const Delegate) void {}

    pub var did_call: bool = false;
    pub const Call = Task.define("Call", call, .{});
    fn call(_: *const Delegate) void {
        did_call = true;
    }

    pub const Crash = Task.define("Crash", crash, .{});
    fn crash(_: *const Delegate) error{Fail}!void {
        return error.Fail;
    }

    pub const Failable = Task.define("Failable", failable, .{});
    fn failable(_: *const Delegate, fail: bool) error{Fail}!void {
        if (fail) return error.Fail;
    }

    pub const Multiply = Task.define("Multiply", multiply, .{});
    fn multiply(_: *const Delegate, a: usize, b: usize) usize {
        return a * b;
    }

    pub const Service = struct { value: usize };

    pub const InjectMultiply = Task.define("InjectMultiply", injectMultiply, .{
        .inject = &.{Service},
    });
    fn injectMultiply(_: *const Delegate, service: *Service, n: usize) usize {
        return n * service.value;
    }

    pub const OptInjectMultiply = Task.define("OptInjectMultiply", optInjectMultiply, .{
        .inject = &.{Service},
    });
    fn optInjectMultiply(_: *const Delegate, service: ?*Service, n: usize) usize {
        const m: usize = if (service) |t| t.value else 1;
        return n * m;
    }
};
