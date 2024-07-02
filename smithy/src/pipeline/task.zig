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
    evalFn: ?*const anyopaque,
    Fn: type,

    pub const Options = struct {
        /// Services that are provided by the scope.
        inject: []const type = &.{},
    };

    pub fn define(name: []const u8, comptime func: anytype, comptime options: Options) Task {
        const name_err = "Task '" ++ name ++ "'";
        const fn_meta = DestructFunc.from(name_err, func, options.inject);
        return .{
            .name = name,
            .inject = if (fn_meta.inject.len > 0) fn_meta.inject else null,
            .input = if (fn_meta.input.len > 0) fn_meta.input else null,
            .output = fn_meta.output,
            .evalFn = null,
            .func = func,
            .Fn = fn_meta.Fn,
        };
    }

    /// A special unimplemented-task, used as a placeholder that may be overridden by the pipeline.
    pub fn hook(name: []const u8, comptime input: ?[]const type, comptime Output: type) Task {
        return .{
            .name = name,
            .inject = null,
            .input = if (input) |in| (if (in.len > 0) in else null) else input,
            .output = Output,
            .evalFn = null,
            .func = undefined,
            .Fn = @TypeOf(.hook_unimplemented),
        };
    }

    pub fn evaluate(comptime self: Task, delegate: *const Delegate, input: self.In(false)) self.Out(.retain) {
        if (comptime self.evalFn) |f| {
            const EvalFn = *const fn (delegate: *const Delegate, input: self.In(false)) self.Out(.retain);
            const evalFn: EvalFn = @ptrCast(@alignCast(f));
            return evalFn(delegate, input);
        } else if (comptime self.Fn == @TypeOf(.hook_unimplemented)) {
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
            comptime var shift: usize = 0;
            var tuple = ArgsValueBuilder(self.In(true)){};
            tuple.appendValue(&shift, delegate);

            if (self.inject) |inj| {
                inline for (inj) |T| tuple.appendInjectable(&shift, delegate, T) catch {
                    const message = "Task '{s}' requires injectable service `{s}`";
                    logOrPanic(message, .{ self.name, @typeName(T) });
                };
            }

            inline for (0..types.len) |i| tuple.appendValue(&shift, input[i]);
            break :blk tuple.consume(&shift);
        } else .{delegate};

        const func: self.Fn = @ptrCast(@alignCast(self.func));
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
        const input = if (self.input) |t| t.len else 0;
        const inject = if (self.inject) |t| t.len else 0;
        const total = if (with_inject) 1 + inject + input else input;

        if (!with_inject and total == 0) {
            return @TypeOf(.{});
        } else if (with_inject and total == 1) {
            return struct { *const Delegate };
        } else {
            var tuple = ArgsTypeBuilder(total){};
            if (with_inject) {
                tuple.append(*const Delegate);
                if (self.inject) |types| tuple.appendMany(types);
            }
            if (self.input) |types| tuple.appendMany(types);
            return tuple.Define();
        }
    }

    pub fn Callback(comptime task: Task) type {
        return if (task.Out(.retain) == void)
            *const fn (ctx: *const anyopaque) anyerror!void
        else
            *const fn (ctx: *const anyopaque, output: task.Out(.retain)) anyerror!void;
    }
};

pub const AbstractTaskOptions = struct {
    /// Services that are provided by the scope.
    inject: []const type = &.{},
    /// Input passed from the wrapper to the child task.
    varyings: []const type = &.{},
};

pub fn AbstractTask(comptime wrapperFn: anytype, comptime wrap_options: AbstractTaskOptions) type {
    const varyings_len = wrap_options.varyings.len;
    const wrap_meta = DestructFunc.from("Abstract task", wrapperFn, wrap_options.inject);

    comptime var wrap_input: []const type = &.{};
    const WrapOut: type = wrap_meta.output;
    const Varyings: type, const ChildOut: type = blk: {
        var eval_meta: ?ZigType.Fn = null;
        const in_len = wrap_meta.input.len;
        if (in_len > 0) {
            wrap_input = wrap_meta.input[0 .. in_len - 1];
            switch (@typeInfo(wrap_meta.input[in_len - 1])) {
                .Pointer => |t| {
                    const target = @typeInfo(t.child);
                    if (t.size == .One and target == .Fn) eval_meta = target.Fn;
                },
                else => {},
            }
        }
        const meta = eval_meta orelse @compileError("Abstract task’s last parameter must be a pointer to a function");
        const Out = meta.return_type.?;

        const params_len = meta.params.len;
        if (wrap_input.len + varyings_len == 0) {
            if (params_len > 0) @compileError("Abstract child-task evaluator expects no parameters");
            break :blk .{ void, Out };
        }

        const tuple_fields = fld: {
            if (params_len == 1) switch (@typeInfo(meta.params[0].type.?)) {
                .Struct => |t| if (t.is_tuple) break :fld t.fields,
                else => {},
            };
            @compileError("Abstract child-task evaluator expects a single tuple parameter");
        };

        if (tuple_fields.len > varyings_len) {
            @compileError("Abstract child-task evaluator tuple exceeds the options.varyings definition");
        }

        var tuple = ArgsTypeBuilder(varyings_len){};
        for (wrap_options.varyings, 0..) |T, i| {
            if (tuple_fields.len < i + 1) @compileError(std.fmt.comptimePrint(
                "Abstract child-task evaluator is missing varying parameter #{d} of type {s}",
                .{ i, @typeName(T) },
            )) else if (T != tuple_fields[i].type) @compileError(std.fmt.comptimePrint(
                "Abstract child-task evaluator’s parameter #{d} expects type {s}",
                .{ i, @typeName(T) },
            ));
            tuple.append(T);
        }
        const zibi_dibi_foo_bar_baz = tuple.Define();

        break :blk .{ zibi_dibi_foo_bar_baz, Out };
    };

    const EvalTaskFn = *const @Type(ZigType{ .Fn = .{
        .calling_convention = .Unspecified,
        .is_generic = false,
        .is_var_args = false,
        .return_type = ChildOut,
        .params = if (varyings_len == 0) &.{} else &.{
            .{ .type = Varyings, .is_generic = false, .is_noalias = false },
        },
    } });

    return struct {
        pub fn define(name: []const u8, comptime func: anytype, comptime options: Task.Options) Task {
            const name_err = "Task '" ++ name ++ "'";
            const child_meta = DestructFunc.from(name_err, func, options.inject);
            if (child_meta.output != ChildOut) {
                @compileError(name_err ++ " expects return type " ++ @typeName(ChildOut));
            }

            const param_shift = 1 + wrap_meta.inject.len;
            for (wrap_options.varyings, 0..) |T, i| {
                if (i + 1 > child_meta.input.len) @compileError(std.fmt.comptimePrint(
                    "Task '{s}' is missing parameter #{d} of type {s}",
                    .{ name, i + param_shift, @typeName(T) },
                )) else if (T != child_meta.input[i]) @compileError(std.fmt.comptimePrint(
                    "Task '{s}' parameter #{d} expects type {s}",
                    .{ name, i + param_shift, @typeName(T) },
                ));
            }

            const child_input_len = child_meta.input.len - varyings_len;
            const invoke_in_len = wrap_input.len + child_input_len;
            const child_input = if (child_input_len > 0) child_meta.input[varyings_len..child_meta.input.len] else &.{};
            const InvokeIn: type, const invoke_input: []const type = if (invoke_in_len == 0)
                .{ @TypeOf(.{}), &.{} }
            else blk: {
                var tuple = ArgsTypeBuilder(invoke_in_len){};
                tuple.appendMany(wrap_input);
                tuple.appendMany(child_input);
                break :blk .{ tuple.Define(), wrap_input ++ child_input };
            };

            const WrapArgs = if (wrap_input.len + wrap_meta.inject.len == 0)
                struct { *const Delegate, EvalTaskFn }
            else blk: {
                var tuple = ArgsTypeBuilder(2 + wrap_meta.inject.len + wrap_input.len){};
                tuple.append(*const Delegate);
                tuple.appendMany(wrap_meta.inject);
                tuple.appendMany(wrap_input);
                tuple.append(EvalTaskFn);
                break :blk tuple.Define();
            };

            const child_args_len = 1 + child_meta.inject.len + varyings_len + child_input.len;
            const ChildArgs = if (child_args_len == 1) .{*const Delegate} else blk: {
                var tuple = ArgsTypeBuilder(child_args_len){};
                tuple.append(*const Delegate);
                tuple.appendMany(child_meta.inject);
                tuple.appendMany(wrap_options.varyings);
                tuple.appendMany(child_input);
                break :blk tuple.Define();
            };

            const evals = struct {
                threadlocal var child_delegate: *const Delegate = undefined;
                threadlocal var invoke_inputs: *const InvokeIn = undefined;

                fn evaluateWrapper(delegate: *const Delegate, input: InvokeIn) WrapOut {
                    const childFn: EvalTaskFn = if (varyings_len == 0) evaluateChildParamless else evaluateChild;
                    const args: WrapArgs = if (wrap_input.len + wrap_meta.inject.len == 0)
                        .{ delegate, childFn }
                    else blk: {
                        comptime var shift: usize = 0;
                        var tuple = ArgsValueBuilder(WrapArgs){};
                        tuple.appendValue(&shift, delegate);
                        inline for (wrap_meta.inject) |T| tuple.appendInjectable(&shift, delegate, T) catch {
                            const message = "Task '{s}' requires injectable service `{s}`";
                            logOrPanic(message, .{ name, @typeName(T) });
                        };
                        inline for (0..wrap_input.len) |i| {
                            tuple.appendValue(&shift, input[i]);
                        }
                        tuple.appendValue(&shift, childFn);
                        break :blk tuple.consume(&shift);
                    };

                    child_delegate = delegate;
                    invoke_inputs = &input;
                    return @call(.auto, wrapperFn, args);
                }

                fn evaluateChildParamless() ChildOut {
                    return evaluateChild({});
                }

                fn evaluateChild(varyings: Varyings) ChildOut {
                    const child_args = if (child_args_len == 1) .{child_delegate} else blk: {
                        comptime var shift: usize = 0;
                        var tuple = ArgsValueBuilder(ChildArgs){};
                        tuple.appendValue(&shift, child_delegate);
                        inline for (child_meta.inject) |T| {
                            tuple.appendInjectable(&shift, child_delegate, T) catch {
                                const message = "Task '{s}' requires injectable service `{s}`";
                                logOrPanic(message, .{ name, @typeName(T) });
                            };
                        }
                        inline for (0..varyings.len) |i| {
                            tuple.appendValue(&shift, varyings[i]);
                        }
                        inline for (wrap_input.len..invoke_inputs.len) |i| {
                            tuple.appendValue(&shift, invoke_inputs[i]);
                        }
                        break :blk tuple.consume(&shift);
                    };

                    return @call(.auto, func, child_args);
                }
            };

            return .{
                .name = name,
                .inject = null,
                .input = if (invoke_in_len > 0) invoke_input else null,
                .output = WrapOut,
                .func = func,
                .evalFn = evals.evaluateWrapper,
                .Fn = *const fn (delegate: *const Delegate, input: InvokeIn) WrapOut,
            };
        }

        /// A special unimplemented-task, used as a placeholder that may be overridden by the pipeline.
        pub fn hook(name: []const u8, comptime input: ?[]const type) Task {
            return .{
                .name = name,
                .inject = null,
                .input = if (input != null and input.?.len > 0) input else null,
                .output = WrapOut,
                .evalFn = null,
                .func = undefined,
                .Fn = @TypeOf(.hook_unimplemented),
            };
        }
    };
}

const DestructFunc = struct {
    inject: []const type,
    input: []const type,
    output: type,
    Fn: type,

    fn from(name: []const u8, comptime func: anytype, comptime inject_types: []const type) DestructFunc {
        const meta: ZigType.Fn = blk: {
            switch (@typeInfo(@TypeOf(func))) {
                .Fn => |t| break :blk t,
                .Pointer => |t| {
                    const target = @typeInfo(t.child);
                    if (t.size == .One and target == .Fn) break :blk target.Fn;
                },
                else => {},
            }
            @compileError(name ++ " expects a function type");
        };

        const params_len = meta.params.len;
        if (params_len == 0 or meta.params[0].type != *const Delegate) {
            @compileError(name ++ " first parameter must be `*const Delegate`");
        }

        const inject_len = inject_types.len;
        const inject = if (inject_len > 0) blk: {
            if (inject_len == 0) break :blk &.{};
            var types: [inject_len]type = undefined;
            for (0..inject_len) |i| {
                const T = inject_types[i];
                switch (@typeInfo(T)) {
                    .Struct => {},
                    .Pointer, .Optional => @compileError(std.fmt.comptimePrint(
                        "{s} options.inject[{d}] expects a plain struct type, without modifiers",
                        .{ name, i },
                    )),
                    else => if (@typeInfo(T) != .Struct) @compileError(std.fmt.comptimePrint(
                        "{s} options.inject[{d}] expects a struct type",
                        .{ name, i },
                    )),
                }

                if (params_len < i + 2) @compileError(std.fmt.comptimePrint(
                    "{s} missing parameter #{d} of type *{2s} or ?*{2s}",
                    .{ name, i + 1, @typeName(T) },
                ));

                var is_optional = false;
                var Param = meta.params[i + 1].type.?;
                if (@typeInfo(Param) == .Optional) {
                    is_optional = true;
                    Param = @typeInfo(Param).Optional.child;
                }

                if (Param != *T) @compileError(std.fmt.comptimePrint(
                    "{s} parameter #{d} expects type {s}*{s}",
                    .{ name, i + 1, if (is_optional) "?" else "", @typeName(T) },
                ));

                types[i] = if (is_optional) ?*T else *T;
            }
            const static = types;
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
            .inject = inject,
            .input = input,
            .output = meta.return_type.?,
            .Fn = *const @Type(.{ .Fn = meta }),
        };
    }
};

fn ArgsTypeBuilder(comptime len: usize) type {
    return struct {
        const Self = @This();

        i: usize = 0,
        fields: [len]ZigType.StructField = undefined,

        pub fn append(self: *Self, T: type) void {
            std.debug.assert(self.i < len);
            self.fields[self.i] = .{
                .name = std.fmt.comptimePrint("{d}", .{self.i}),
                .type = T,
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(T),
            };
            self.i += 1;
        }

        pub fn appendMany(self: *Self, types: []const type) void {
            for (types) |T| self.append(T);
        }

        pub fn Define(self: Self) type {
            std.debug.assert(self.i == len);
            return @Type(ZigType{ .Struct = .{
                .is_tuple = true,
                .layout = .auto,
                .fields = &self.fields,
                .decls = &.{},
            } });
        }
    };
}

fn ArgsValueBuilder(comptime T: type) type {
    const len = @typeInfo(T).Struct.fields.len;
    return struct {
        const Self = @This();

        tuple: T = undefined,

        pub inline fn appendValue(self: *Self, i: *usize, value: anytype) void {
            comptime std.debug.assert(i.* < len);
            const field: []const u8 = comptime std.fmt.comptimePrint("{d}", .{i.*});
            @field(self.tuple, field) = value;
            comptime i.* += 1;
        }

        pub inline fn appendInjectable(self: *Self, i: *usize, delegate: *const Delegate, comptime F: type) !void {
            const Ref = switch (@typeInfo(F)) {
                .Optional => |t| t.child,
                else => F,
            };
            const is_optional = F != Ref;
            const value = delegate.scope.getService(Ref) orelse
                if (is_optional) null else return error.NoService;
            self.appendValue(i, value);
        }

        pub inline fn consume(self: Self, i: *usize) T {
            comptime std.debug.assert(i.* == len);
            return self.tuple;
        }
    };
}

inline fn logOrPanic(comptime fmt: []const u8, args: anytype) void {
    if (std.debug.runtime_safety) {
        std.log.err(fmt, args);
        unreachable;
    } else {
        std.debug.panic(fmt, args);
    }
}

test "Task.define" {
    try testing.expectEqualDeep(Task{
        .name = "NoOp",
        .inject = null,
        .input = null,
        .output = void,
        .evalFn = null,
        .func = tests.noOpFn,
        .Fn = *const @TypeOf(tests.noOpFn),
    }, tests.NoOp);

    try testing.expectEqualDeep(Task{
        .name = "Crash",
        .inject = null,
        .input = null,
        .output = error{Fail}!void,
        .evalFn = null,
        .func = tests.crashFn,
        .Fn = *const @TypeOf(tests.crashFn),
    }, tests.Crash);

    comptime try testing.expectEqualDeep(Task{
        .name = "Multiply",
        .inject = null,
        .input = &.{ usize, usize },
        .output = usize,
        .evalFn = null,
        .func = tests.multiplyFn,
        .Fn = *const @TypeOf(tests.multiplyFn),
    }, tests.Multiply);

    comptime try testing.expectEqualDeep(Task{
        .name = "InjectMultiply",
        .inject = &.{*tests.Service},
        .input = &.{usize},
        .output = usize,
        .evalFn = null,
        .func = tests.injectMultiplyFn,
        .Fn = *const @TypeOf(tests.injectMultiplyFn),
    }, tests.InjectMultiply);

    comptime try testing.expectEqualDeep(Task{
        .name = "OptInjectMultiply",
        .inject = &.{?*tests.Service},
        .input = &.{usize},
        .output = usize,
        .evalFn = null,
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

test "AbstractTask" {
    const GenericEval = struct {
        fn wrapperCall(_: *const Delegate, task: *const fn () void) void {
            return task();
        }

        fn wrapperVarying(
            _: *const Delegate,
            n: usize,
            task: *const fn (struct { usize }) usize,
        ) usize {
            return task(.{n});
        }

        fn childVarying(_: *const Delegate, a: usize, b: usize) usize {
            return a + b;
        }
    };

    tests.did_call = false;
    const GenericCall = AbstractTask(GenericEval.wrapperCall, .{});
    const Call = GenericCall.define("Abstract Call", tests.callFn, .{});
    Call.evaluate(&NOOP_DELEGATE, .{});
    try testing.expect(tests.did_call);

    const GenericVarying = AbstractTask(GenericEval.wrapperVarying, .{
        .varyings = &.{usize},
    });
    const Varying = GenericVarying.define("Abstract Varying", GenericEval.childVarying, .{});
    try testing.expectEqual(108, Varying.evaluate(&NOOP_DELEGATE, .{ 100, 8 }));
}

/// Evaluate a task with a no-op delegate.
pub fn tester(comptime task: Task, input: task.In(false)) task.Out(.retain) {
    return task.evaluate(&NOOP_DELEGATE, input);
}

test "tester" {
    tests.did_call = false;
    tester(tests.Call, .{});
    try testing.expect(tests.did_call);

    try testing.expectEqual(108, tester(tests.Multiply, .{ 2, 54 }));

    try tester(tests.Failable, .{false});
    try testing.expectError(error.Fail, tester(tests.Failable, .{true}));
}

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
