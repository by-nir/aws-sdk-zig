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
    In: type,
    Out: type,
    evaluator: *const Evaluator,
    meta: ?*const anyopaque = null,

    pub const Options = struct {
        /// Services that are provided by the scope.
        injects: []const type = &.{},
    };

    pub const Evaluator = struct {
        evalFn: *const anyopaque,
        overrideFn: ?OverrideFactoryFn = null,
    };

    pub const OverrideFactoryFn = *const fn (
        comptime task: Task,
        name: []const u8,
        comptime taskFn: anytype,
        comptime options: Task.Options,
    ) Task;

    pub fn Payload(comptime self: Task) type {
        return util.StripError(self.Out);
    }

    pub fn Define(name: []const u8, comptime taskFn: anytype, comptime options: Options) Task {
        return StandardTask(taskFn, options).Define(name);
    }

    /// A special task, used as a placeholder intended to be overriden.
    /// Evaluating this task without previously providing an implementation will panic.
    pub fn Hook(name: []const u8, comptime Output: type, comptime input: []const type) Task {
        return StandardHook(Output, input).Define(name);
    }

    pub fn evaluate(comptime self: Task, delegate: *const Delegate, input: self.In) self.Out {
        const EvalFn = *const fn (name: []const u8, delegate: *const Delegate, input: self.In) self.Out;
        const evalFn: EvalFn = @ptrCast(@alignCast(self.evaluator.evalFn));
        return evalFn(self.name, delegate, input);
    }

    pub fn isFailable(comptime self: Task) bool {
        return @typeInfo(self.Out) == .error_union;
    }

    pub fn Callback(comptime task: Task) type {
        return if (task.Out == void)
            *const fn (ctx: *const anyopaque) anyerror!void
        else
            *const fn (ctx: *const anyopaque, output: task.Out) anyerror!void;
    }
};

pub fn StandardTask(comptime taskFn: anytype, comptime options: Task.Options) type {
    const meta = DestructFunc.from("Standard task", taskFn, options.injects);
    const EvalInput: type = if (meta.inputs.len > 0) std.meta.Tuple(meta.inputs) else struct {};

    return struct {
        pub fn Define(name: []const u8) Task {
            return .{
                .name = name,
                .In = EvalInput,
                .Out = meta.Out,
                .evaluator = &Task.Evaluator{
                    .evalFn = evaluate,
                    .overrideFn = standardOverride,
                },
            };
        }

        fn evaluate(name: []const u8, delegate: *const Delegate, input: EvalInput) meta.Out {
            const args = if (meta.injects.len + meta.inputs.len > 0) blk: {
                comptime var shift: usize = 0;
                var tuple = util.TupleFiller(meta.Args){};
                tuple.append(&shift, delegate);
                inline for (meta.injects) |T| {
                    const service = getInjectable(delegate, T, name);
                    tuple.append(&shift, service);
                }
                inline for (0..meta.inputs.len) |i| tuple.append(&shift, input[i]);
                break :blk tuple.consume(&shift);
            } else .{delegate};

            return @call(.auto, taskFn, args);
        }
    };
}

test "StandardTask" {
    tests.did_call = false;
    tests.Call.evaluate(&NOOP_DELEGATE, .{});
    try testing.expect(tests.did_call);

    const value = tests.Multiply.evaluate(&NOOP_DELEGATE, .{ 2, 54 });
    try testing.expectEqual(108, value);
}

pub fn StandardHook(comptime Output: type, comptime inputs: []const type) type {
    const InvokeInput: type = if (inputs.len > 0) std.meta.Tuple(inputs) else struct {};
    return struct {
        pub fn Define(name: []const u8) Task {
            return .{
                .name = name,
                .In = InvokeInput,
                .Out = Output,
                .evaluator = &Task.Evaluator{
                    .evalFn = evaluate,
                    .overrideFn = standardOverride,
                },
            };
        }

        pub fn evaluate(name: []const u8, _: *const Delegate, _: InvokeInput) Output {
            const message = "Hook '{s}' is not implemented";
            if (std.debug.runtime_safety) {
                std.log.err(message, .{name});
                unreachable;
            } else {
                std.debug.panic(message, .{name});
            }
        }
    };
}

fn standardOverride(comptime task: Task, name: []const u8, comptime taskFn: anytype, comptime options: Task.Options) Task {
    const fn_meta = DestructFunc.from("Overriding '" ++ task.name ++ "'", taskFn, options.injects);
    if (task.Out != fn_meta.Out) @compileError(std.fmt.comptimePrint(
        "Overriding '{s}' expects output type `{}`",
        .{ task.name, task.Out },
    ));

    const shift = 1 + options.injects.len;
    const fields = @typeInfo(task.In).@"struct".fields;
    if (fn_meta.inputs.len + fields.len > 0) {
        if (fields.len != fn_meta.inputs.len) @compileError(std.fmt.comptimePrint(
            "Overriding '{s}' expects {d} parameters",
            .{ task.name, shift + fields.len },
        ));

        for (fields, 0..) |field, i| {
            const T = field.type;
            if (T != fn_meta.inputs[i]) @compileError(std.fmt.comptimePrint(
                "Overriding '{s}' expects parameter #{d} of type `{}`",
                .{ task.name, shift + i, T },
            ));
        }
    }

    return StandardTask(taskFn, options).Define(name ++ " (overrides '" ++ task.name ++ "'')");
}

pub fn getInjectable(delegate: *const Delegate, comptime T: type, task_name: []const u8) T {
    const Ref = switch (@typeInfo(T)) {
        .optional => |t| t.child,
        else => T,
    };
    const is_optional = T != Ref;
    return delegate.scope.getService(Ref) orelse if (is_optional) null else {
        const message = "Evaluating task '{s}' expects the scope to provide `{}`";
        util.logOrPanic(message, .{ task_name, T });
    };
}

pub const DestructFunc = struct {
    Fn: type,
    Args: type,
    Out: type,
    injects: []const type,
    inputs: []const type,

    pub fn from(factory_name: []const u8, comptime func: anytype, comptime inject_types: []const type) DestructFunc {
        const meta: ZigType.Fn = blk: {
            switch (@typeInfo(@TypeOf(func))) {
                .@"fn" => |t| break :blk t,
                .pointer => |t| {
                    const target = @typeInfo(t.child);
                    if (t.size == .One and target == .@"fn") break :blk target.@"fn";
                },
                else => {},
            }
            @compileError(factory_name ++ " expects a function type");
        };

        const params_len = meta.params.len;
        if (params_len == 0 or meta.params[0].type != *const Delegate) {
            @compileError(factory_name ++ " first parameter must be `*const Delegate`");
        }

        const inject_len = inject_types.len;
        const inject = comptime if (inject_len > 0) blk: {
            if (inject_len == 0) break :blk &.{};
            var types: [inject_len]type = undefined;
            for (0..inject_len) |i| {
                const T = inject_types[i];
                switch (@typeInfo(T)) {
                    .@"struct" => {},
                    .pointer, .optional => @compileError(std.fmt.comptimePrint(
                        "{s} inject options #{d} expects a plain struct type, without modifiers",
                        .{ factory_name, i },
                    )),
                    else => if (@typeInfo(T) != .@"struct") @compileError(std.fmt.comptimePrint(
                        "{s} inject options #{d} expects a struct type",
                        .{ factory_name, i },
                    )),
                }

                if (params_len < i + 2) @compileError(std.fmt.comptimePrint(
                    "{s} missing parameter #{d} of type `*{}` or `?*{2}`",
                    .{ factory_name, i + 1, T },
                ));

                var is_optional = false;
                var Param = meta.params[i + 1].type.?;
                if (@typeInfo(Param) == .optional) {
                    is_optional = true;
                    Param = @typeInfo(Param).optional.child;
                }

                if (Param != *T) @compileError(std.fmt.comptimePrint(
                    "{s} expects parameter #{d} of type `{s}*{}`",
                    .{ factory_name, i + 1, if (is_optional) "?" else "", T },
                ));

                types[i] = if (is_optional) ?*T else *T;
            }
            const static: [inject_len]type = types;
            break :blk &static;
        } else &.{};

        const input_len = params_len - inject_len - 1;
        const input = comptime if (input_len > 0) blk: {
            var types: [input_len]type = undefined;
            for (0..input_len) |i| {
                types[i] = meta.params[i + 1 + inject_len].type.?;
            }
            const static = types;
            break :blk &static;
        } else &.{};

        return .{
            .Fn = *const @Type(.{ .@"fn" = meta }),
            .Args = std.meta.ArgsTuple(@Type(.{ .@"fn" = meta })),
            .Out = meta.return_type.?,
            .injects = inject,
            .inputs = input,
        };
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

    pub fn alloc(self: Delegate) Allocator {
        return self.scope.alloc();
    }

    pub fn evaluate(self: *const Delegate, comptime task: Task, input: task.In) !task.Payload() {
        return self.scheduler.evaluate(self, task, input);
    }

    pub fn schedule(self: *const Delegate, comptime task: Task, input: task.In) !void {
        if (task.Payload() != void)
            @compileError("Task '" ++ task.name ++ "' returns a value, use `scheduleCallback` instead.");

        try self.scheduler.appendAsync(self, task, input);
    }

    pub fn scheduleCallback(
        self: *const Delegate,
        comptime task: Task,
        input: task.In,
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
