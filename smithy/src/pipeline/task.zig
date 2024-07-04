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
        overrideFn: *const fn (comptime task: Task, name: []const u8, comptime taskFn: anytype, comptime options: Task.Options) Task,
    };

    pub fn Payload(comptime self: Task) type {
        return switch (@typeInfo(self.Out)) {
            .ErrorUnion => |t| t.payload,
            else => self.Out,
        };
    }

    pub fn define(name: []const u8, comptime taskFn: anytype, comptime options: Options) Task {
        return StandardTask(taskFn, options).define(name);
    }

    /// A special task, used as a placeholder intended to be overriden.
    /// Evaluating this task without previously providing an implementation will panic.
    pub fn hook(name: []const u8, comptime input: []const type, comptime Output: type) Task {
        return StandardHook(input, Output).define(name);
    }

    pub fn evaluate(comptime self: Task, delegate: *const Delegate, input: self.In) self.Out {
        const EvalFn = *const fn (name: []const u8, delegate: *const Delegate, input: self.In) self.Out;
        const evalFn: EvalFn = @ptrCast(@alignCast(self.evaluator.evalFn));
        return evalFn(self.name, delegate, input);
    }

    pub fn isFailable(comptime self: Task) bool {
        return @typeInfo(self.Out) == .ErrorUnion;
    }

    pub fn Callback(comptime task: Task) type {
        return if (task.Out == void)
            *const fn (ctx: *const anyopaque) anyerror!void
        else
            *const fn (ctx: *const anyopaque, output: task.Out) anyerror!void;
    }
};

fn standardOverride(comptime task: Task, name: []const u8, comptime taskFn: anytype, comptime options: Task.Options) Task {
    const fn_meta = DestructFunc.from("Overriding '" ++ task.name ++ "'", taskFn, options.injects);
    if (task.Out != fn_meta.Output) @compileError(std.fmt.comptimePrint(
        "Overriding '{s}' expects output type {}",
        .{ task.name, @typeName(task.FnOut) },
    ));

    const shift = 1 + options.injects.len;
    const fields = @typeInfo(task.In).Struct.fields;
    if (fn_meta.inputs.len + fields.len > 0) {
        if (fields.len != fn_meta.inputs.len) @compileError(std.fmt.comptimePrint(
            "Overriding '{s}' expects {d} parameters",
            .{ task.name, shift + fields.len },
        ));

        for (fields, 0..) |field, i| {
            const T = field.type;
            if (T != fn_meta.inputs[i]) @compileError(std.fmt.comptimePrint(
                "Overriding '{s}' expects parameter #{d} of type {s}",
                .{ task.name, shift + i, @typeName(T) },
            ));
        }
    }

    return StandardTask(taskFn, options).define(name ++ " (overrides '" ++ task.name ++ "'')");
}

fn StandardTask(comptime taskFn: anytype, comptime options: Task.Options) type {
    const meta = DestructFunc.from("Standard task", taskFn, options.injects);
    const EvalInput: type = if (meta.inputs.len > 0) std.meta.Tuple(meta.inputs) else @TypeOf(.{});

    return struct {
        pub fn define(name: []const u8) Task {
            return .{
                .name = name,
                .In = EvalInput,
                .Out = meta.Output,
                .evaluator = &Task.Evaluator{
                    .evalFn = evaluate,
                    .overrideFn = standardOverride,
                },
            };
        }

        fn evaluate(name: []const u8, delegate: *const Delegate, input: EvalInput) meta.Output {
            const args = if (meta.injects.len + meta.inputs.len > 0) blk: {
                comptime var shift: usize = 0;
                var tuple = ArgsFiller(meta.Args){};
                tuple.appendValue(&shift, delegate);
                inline for (meta.injects) |T| tuple.appendInjectable(name, &shift, delegate, T);
                inline for (0..meta.inputs.len) |i| tuple.appendValue(&shift, input[i]);
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

fn StandardHook(comptime inputs: []const type, comptime Output: type) type {
    const InvokeInput: type = if (inputs.len > 0) std.meta.Tuple(inputs) else @TypeOf(.{});
    return struct {
        pub fn define(name: []const u8) Task {
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

        fn evaluate(name: []const u8, _: *const Delegate, _: InvokeInput) Output {
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

pub const AbstractTaskOptions = struct {
    /// Services that are provided by the scope.
    injects: []const type = &.{},
    /// Input passed from the wrapper to the child task.
    varyings: []const type = &.{},
};

pub fn AbstractTask(abst_name: []const u8, comptime wrapFn: anytype, comptime wrap_options: AbstractTaskOptions) type {
    const wrap_meta = DestructAbstract.from(abst_name, wrapFn, wrap_options);
    return struct {
        const Meta = struct {
            ChildFn: type,
            childFn: *const anyopaque,
            child_inputs: []const type,
            child_options: Task.Options,
        };

        pub fn define(name: []const u8, comptime taskFn: anytype, comptime options: Task.Options) Task {
            const child_meta = DestructFunc.from("Abstract '" ++ abst_name ++ "' task", taskFn, options.injects);
            wrap_meta.validateChildOutput(child_meta.Output);
            wrap_meta.validateChildVaryings(child_meta.inputs, 1 + child_meta.injects.len);

            const child_inputs = wrap_meta.childInputs(child_meta.inputs);
            const ChildArgs = wrap_meta.ChildArgs(child_meta.injects, child_inputs);

            const invoke_inputs = wrap_meta.invokeInputs(child_inputs);
            const InvokeInput: type = if (invoke_inputs.len > 0) std.meta.Tuple(invoke_inputs) else @TypeOf(.{});

            const Eval = struct {
                threadlocal var pass_delegate: *const Delegate = undefined;
                threadlocal var pass_inputs: *const InvokeInput = undefined;

                fn wrap(tsk_name: []const u8, delegate: *const Delegate, input: InvokeInput) wrap_meta.WrapOut {
                    const proxyFn: wrap_meta.ProxyFn = if (wrap_meta.varyings.len == 0) childParamless else child;
                    const args: wrap_meta.WrapArgs = if (wrap_meta.injects.len + wrap_meta.inputs.len == 0)
                        .{ delegate, proxyFn }
                    else blk: {
                        comptime var shift: usize = 0;
                        var tuple = ArgsFiller(wrap_meta.WrapArgs){};
                        tuple.appendValue(&shift, delegate);
                        inline for (wrap_meta.injects) |T| tuple.appendInjectable(tsk_name, &shift, delegate, T);
                        inline for (0..wrap_meta.inputs.len) |i| {
                            tuple.appendValue(&shift, input[i]);
                        }
                        tuple.appendValue(&shift, proxyFn);
                        break :blk tuple.consume(&shift);
                    };

                    pass_inputs = &input;
                    pass_delegate = delegate;
                    return @call(.auto, wrapFn, args);
                }

                fn childParamless() wrap_meta.ChildOut {
                    return child(.{});
                }

                fn child(varyings: wrap_meta.Varyings) wrap_meta.ChildOut {
                    if (@typeInfo(ChildArgs).Struct.fields.len == 1) {
                        @call(.auto, taskFn, .{pass_delegate});
                    } else {
                        comptime var shift: usize = 0;
                        var tuple = ArgsFiller(ChildArgs){};
                        tuple.appendValue(&shift, pass_delegate);
                        inline for (child_meta.injects) |T| {
                            tuple.appendInjectable(name, &shift, pass_delegate, T);
                        }
                        inline for (0..varyings.len) |i| {
                            tuple.appendValue(&shift, varyings[i]);
                        }
                        inline for (wrap_meta.inputs.len..pass_inputs.len) |i| {
                            tuple.appendValue(&shift, pass_inputs[i]);
                        }
                        const args = tuple.consume(&shift);

                        return @call(.auto, taskFn, args);
                    }
                }
            };

            return .{
                .name = name,
                .In = InvokeInput,
                .Out = wrap_meta.WrapOut,
                .evaluator = &Task.Evaluator{
                    .evalFn = Eval.wrap,
                    .overrideFn = override,
                },
                .meta = &Meta{
                    .ChildFn = child_meta.Fn,
                    .childFn = taskFn,
                    .child_inputs = child_inputs,
                    .child_options = options,
                },
            };
        }

        /// A special task, used as a placeholder intended to be overriden.
        /// Evaluating this task without previously providing an implementation will panic.
        pub fn hook(name: []const u8, comptime input: []const type) Task {
            const invoke_inputs = wrap_meta.invokeInputs(input);
            const InvokeInput: type = if (invoke_inputs.len > 0) std.meta.Tuple(invoke_inputs) else @TypeOf(.{});

            return .{
                .name = name,
                .In = InvokeInput,
                .Out = wrap_meta.WrapOut,
                .evaluator = &Task.Evaluator{
                    .evalFn = StandardHook(invoke_inputs, wrap_meta.WrapOut).evaluate,
                    .overrideFn = override,
                },
                .meta = &Meta{
                    .ChildFn = void,
                    .childFn = undefined,
                    .child_inputs = input,
                    .child_options = .{},
                },
            };
        }

        fn override(
            comptime task: Task,
            name: []const u8,
            comptime taskFn: anytype,
            comptime options: Task.Options,
        ) Task {
            const fn_meta = DestructFunc.from("Overriding '" ++ task.name ++ "'", taskFn, options.injects);
            if (task.Out != wrap_meta.ChildOut) @compileError(std.fmt.comptimePrint(
                "Overriding '{s}' expects output type {}",
                .{ task.name, @typeName(task.FnOut) },
            ));

            const meta: *const Meta = @ptrCast(@alignCast(task.meta.?));
            const args: []const type = wrap_meta.varyings ++ meta.child_inputs;

            const shift = 1 + options.injects.len;
            if (fn_meta.inputs.len + args.len > 0) {
                if (args.len != fn_meta.inputs.len) @compileError(std.fmt.comptimePrint(
                    "Overriding '{s}' expects {d} parameters",
                    .{ task.name, shift + args.len },
                ));

                for (args, 0..) |T, i| {
                    if (T != fn_meta.inputs[i]) @compileError(std.fmt.comptimePrint(
                        "Overriding '{s}' expects parameter #{d} of type {s}",
                        .{ task.name, shift + i, @typeName(T) },
                    ));
                }
            }

            return define(name ++ " (overrides '" ++ task.name ++ "')", taskFn, options);
        }

        pub fn extractTaskFn(comptime task: Task) Task {
            const meta: *const Meta = @ptrCast(@alignCast(task.meta.?));
            const taskFn: meta.ChildFn = @ptrCast(@alignCast(meta.childFn));
            return StandardTask(taskFn, meta.child_options).define(task.name);
        }

        pub fn ChildInput(comptime task: Task) type {
            const meta: *const Meta = @ptrCast(@alignCast(task.meta.?));
            return std.meta.Tuple(meta.child_inputs);
        }
    };
}

const DestructAbstract = struct {
    name: []const u8,
    ChildOut: type,
    WrapOut: type,
    WrapArgs: type,
    Varyings: type,
    ProxyFn: type,
    injects: []const type,
    varyings: []const type,
    inputs: []const type,

    pub fn from(name: []const u8, comptime wrapFn: anytype, options: AbstractTaskOptions) DestructAbstract {
        const wrap_meta = DestructFunc.from("Abstract task", wrapFn, options.injects);

        const proxy_meta: ZigType.Fn = proxyMeta(wrap_meta);
        const ChildOut = proxy_meta.return_type.?;
        const wrap_inputs = wrap_meta.inputs[0 .. wrap_meta.inputs.len - 1];

        validateWrapVaryings(wrap_inputs, proxy_meta.params, options.varyings);
        const Varyings = std.meta.Tuple(options.varyings);

        const ProxyFn = *const @Type(ZigType{ .Fn = .{
            .calling_convention = .Unspecified,
            .is_generic = false,
            .is_var_args = false,
            .return_type = ChildOut,
            .params = if (options.varyings.len == 0) &.{} else &.{
                .{ .type = Varyings, .is_generic = false, .is_noalias = false },
            },
        } });

        const WrapArgs = if (wrap_inputs.len + options.injects.len == 0)
            struct { *const Delegate, ProxyFn }
        else
            std.meta.Tuple(&[_]type{*const Delegate} ++ options.injects ++ wrap_inputs ++ &[_]type{ProxyFn});

        return .{
            .name = name,
            .ChildOut = ChildOut,
            .WrapOut = wrap_meta.Output,
            .WrapArgs = WrapArgs,
            .Varyings = Varyings,
            .ProxyFn = ProxyFn,
            .injects = options.injects,
            .varyings = options.varyings,
            .inputs = wrap_inputs,
        };
    }

    fn proxyMeta(comptime wrap_meta: DestructFunc) ZigType.Fn {
        const input_len = wrap_meta.inputs.len;
        if (input_len > 0) switch (@typeInfo(wrap_meta.inputs[input_len - 1])) {
            .Pointer => |t| {
                const target = @typeInfo(t.child);
                if (t.size == .One and target == .Fn) return target.Fn;
            },
            else => {},
        };

        @compileError("Abstract task’s last parameter must be a pointer to a function pointer");
    }

    fn validateWrapVaryings(wrap_input: []const type, params: []const ZigType.Fn.Param, varyings: []const type) void {
        if (wrap_input.len + varyings.len == 0) {
            if (params.len > 0) @compileError("Abstract child–invoker expects no parameters");
            return;
        }

        const fields = fld: {
            if (params.len == 1) switch (@typeInfo(params[0].type.?)) {
                .Struct => |t| if (t.is_tuple) break :fld t.fields,
                else => {},
            };
            @compileError("Abstract child–invoker expects a single tuple parameter");
        };

        if (fields.len > varyings.len) {
            @compileError("Abstract child–invoker tuple exceeds the options.varyings definition");
        }

        for (varyings, 0..) |T, i| {
            if (fields.len < i + 1) @compileError(std.fmt.comptimePrint(
                "Abstract child–invoker is missing varying parameter #{d} of type {s}",
                .{ i, @typeName(T) },
            )) else if (T != fields[i].type) @compileError(std.fmt.comptimePrint(
                "Abstract child–invoker’s expects parameter #{d} of type {s}",
                .{ i, @typeName(T) },
            ));
        }
    }

    pub fn validateChildOutput(wrap: DestructAbstract, T: type) void {
        if (T != wrap.ChildOut) @compileError(std.fmt.comptimePrint(
            "Abstract '{s}' task expects return type {s}",
            .{ wrap.name, @typeName(wrap.ChildOut) },
        ));
    }

    pub fn validateChildVaryings(wrap: DestructAbstract, inputs: []const type, param_shift: usize) void {
        for (wrap.varyings, 0..) |T, i| {
            if (i + 1 > inputs.len) @compileError(std.fmt.comptimePrint(
                "Abstract '{s}' task is missing parameter #{d} of type {s}",
                .{ wrap.name, i + param_shift, @typeName(T) },
            )) else if (T != inputs[i]) @compileError(std.fmt.comptimePrint(
                "Abstract '{s}' task expect parameter #{d} of type {s}",
                .{ wrap.name, i + param_shift, @typeName(T) },
            ));
        }
    }

    pub fn childInputs(wrap: DestructAbstract, child_inputs: []const type) []const type {
        return child_inputs[wrap.varyings.len..child_inputs.len];
    }

    pub fn invokeInputs(wrap: DestructAbstract, child_inputs: []const type) []const type {
        return if (wrap.inputs.len + child_inputs.len > 0) wrap.inputs ++ child_inputs else &.{};
    }

    pub fn ChildArgs(wrap: DestructAbstract, child_injects: []const type, child_inputs: []const type) type {
        if (child_injects.len + wrap.varyings.len + child_inputs.len == 0) {
            return struct { *const Delegate };
        } else {
            const injects: [child_injects.len]type = child_injects[0..child_injects.len].*;
            return std.meta.Tuple(&[_]type{*const Delegate} ++ injects ++ wrap.varyings ++ child_inputs);
        }
    }
};

test "AbstractTask" {
    const Eval = struct {
        fn callWrapper(_: *const Delegate, task: *const fn () void) void {
            return task();
        }

        fn varyingWrapper(
            _: *const Delegate,
            a: usize,
            task: *const fn (struct { usize }) usize,
        ) usize {
            return task(.{a});
        }

        fn varyingChild(_: *const Delegate, a: usize, b: usize) usize {
            return a + b;
        }
    };

    tests.did_call = false;
    const AbstractCall = AbstractTask("Abstract Call", Eval.callWrapper, .{});
    const Call = AbstractCall.define("Test Call", tests.callFn, .{});
    Call.evaluate(&NOOP_DELEGATE, .{});
    try testing.expect(tests.did_call);

    const AbstractVarying = AbstractTask("Abstract Varying", Eval.varyingWrapper, .{
        .varyings = &.{usize},
    });
    const Varying = AbstractVarying.define("Test Varying", Eval.varyingChild, .{});
    try testing.expectEqual(108, Varying.evaluate(&NOOP_DELEGATE, .{ 100, 8 }));

    const fields = @typeInfo(AbstractVarying.ChildInput(Varying)).Struct.fields;
    try testing.expectEqual(1, fields.len);
    try testing.expectEqual(usize, fields[0].type);

    const ExtractVarying = AbstractVarying.extractTaskFn(Varying);
    try testing.expectEqual(108, ExtractVarying.evaluate(&NOOP_DELEGATE, .{ 100, 8 }));
}

const DestructFunc = struct {
    Fn: type,
    Args: type,
    Output: type,
    injects: []const type,
    inputs: []const type,

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
        const inject = comptime if (inject_len > 0) blk: {
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
                    "{s} expects parameter #{d} of type {s}*{s}",
                    .{ name, i + 1, if (is_optional) "?" else "", @typeName(T) },
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
            .Fn = *const @Type(.{ .Fn = meta }),
            .Args = std.meta.ArgsTuple(@Type(.{ .Fn = meta })),
            .Output = meta.return_type.?,
            .injects = inject,
            .inputs = input,
        };
    }
};

fn ArgsFiller(comptime Args: type) type {
    const len = @typeInfo(Args).Struct.fields.len;
    return struct {
        const Self = @This();

        tuple: Args = undefined,

        pub inline fn appendValue(self: *Self, i: *usize, value: anytype) void {
            comptime std.debug.assert(i.* < len);
            const field: []const u8 = comptime std.fmt.comptimePrint("{d}", .{i.*});
            @field(self.tuple, field) = value;
            comptime i.* += 1;
        }

        pub inline fn appendInjectable(
            self: *Self,
            task_name: []const u8,
            i: *usize,
            delegate: *const Delegate,
            comptime T: type,
        ) void {
            const Ref = switch (@typeInfo(T)) {
                .Optional => |t| t.child,
                else => T,
            };
            const is_optional = T != Ref;
            const value = delegate.scope.getService(Ref) orelse if (is_optional) null else {
                const message = "Evaluating task '{s}' expects the scope to provide `{s}`";
                logOrPanic(message, .{ task_name, @typeName(T) });
            };
            self.appendValue(i, value);
        }

        pub inline fn consume(self: Self, i: *usize) Args {
            comptime std.debug.assert(i.* == len);
            return self.tuple;
        }
    };
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

    pub fn evaluate(self: *const Delegate, comptime task: Task, input: task.In) !task.Payload() {
        return self.scheduler.evaluateSync(self, task, input);
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

inline fn logOrPanic(comptime fmt: []const u8, args: anytype) void {
    if (std.debug.runtime_safety) {
        std.log.err(fmt, args);
        unreachable;
    } else {
        std.debug.panic(fmt, args);
    }
}
