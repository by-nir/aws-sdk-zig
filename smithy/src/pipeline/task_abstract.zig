const std = @import("std");
const testing = std.testing;
const ZigType = std.builtin.Type;
const Allocator = std.mem.Allocator;
const util = @import("utils.zig");
const tests = @import("tests.zig");
const tsk = @import("task.zig");
const Task = tsk.Task;
const Delegate = tsk.Delegate;
const DestructFunc = tsk.DestructFunc;
const getInjectable = tsk.getInjectable;
const PipelineTester = @import("pipeline.zig").PipelineTester;

pub const AbstractTaskOptions = struct {
    /// Services that are provided by the scope.
    injects: []const type = &.{},
    /// Input passed from the wrapper to the child task.
    varyings: []const type = &.{},
};

pub const AbstractChainMethod = enum { sync, asyncd };

pub fn AbstractTask(abst_name: []const u8, comptime wrapFn: anytype, comptime wrap_options: AbstractTaskOptions) type {
    const wrap = WrapMeta.from("Abstract task", wrapFn, wrap_options);

    return struct {
        const Meta = struct {
            ChildFn: type,
            childFn: *const anyopaque,
            child_inputs: []const type,
            child_options: Task.Options,
        };

        pub fn Define(name: []const u8, comptime taskFn: anytype, comptime options: Task.Options) Task {
            const child = ChildMeta.from(abst_name, wrap, taskFn, options);

            const Eval = struct {
                threadlocal var proxy_delegate: *const Delegate = undefined;
                threadlocal var proxy_inputs: *const child.InvokeInput = undefined;

                fn evaluate(task_name: []const u8, delegate: *const Delegate, input: child.InvokeInput) wrap.WrapOut {
                    proxy_inputs = &input;
                    proxy_delegate = delegate;
                    const proxyFn: wrap.ProxyFn = if (wrap.varyings.len == 0) proxyParamless else proxy;
                    const args = evalArgs(child.InvokeInput, delegate, proxyFn, input, task_name);
                    return @call(.auto, wrapFn, args);
                }

                fn proxyParamless() wrap.ChildOut {
                    return proxy(.{});
                }

                fn proxy(varyings: wrap.Varyings) wrap.ChildOut {
                    if (@typeInfo(child.ChildArgs).Struct.fields.len == 1) {
                        @call(.auto, taskFn, .{proxy_delegate});
                    } else {
                        comptime var shift: usize = 0;
                        var tuple = util.TupleFiller(child.ChildArgs){};
                        tuple.appendValue(&shift, proxy_delegate);
                        inline for (child.injects) |T| {
                            const service = getInjectable(proxy_delegate, T, name);
                            tuple.appendValue(&shift, service);
                        }
                        inline for (0..varyings.len) |i| tuple.appendValue(&shift, varyings[i]);
                        inline for (wrap.inputs.len..proxy_inputs.len) |i| tuple.appendValue(&shift, proxy_inputs[i]);
                        const args = tuple.consume(&shift);

                        return @call(.auto, taskFn, args);
                    }
                }
            };

            return .{
                .name = name,
                .In = child.InvokeInput,
                .Out = wrap.WrapOut,
                .evaluator = &Task.Evaluator{
                    .evalFn = Eval.evaluate,
                    .overrideFn = override,
                },
                .meta = &Meta{
                    .ChildFn = child.ChildFn,
                    .childFn = taskFn,
                    .child_inputs = child.inputs,
                    .child_options = options,
                },
            };
        }

        pub fn Chain(comptime task: Task, method: AbstractChainMethod) Task {
            const child = ChainMeta.from(abst_name, wrap, task, method);

            const Eval = struct {
                threadlocal var proxy_delegate: *const Delegate = undefined;
                threadlocal var proxy_inputs: *const child.InvokeInput = undefined;

                fn evaluate(task_name: []const u8, delegate: *const Delegate, input: child.InvokeInput) wrap.WrapOut {
                    proxy_inputs = &input;
                    proxy_delegate = delegate;
                    const proxyFn: wrap.ProxyFn = if (wrap.varyings.len == 0) proxyParamless else proxy;
                    const args = evalArgs(child.InvokeInput, delegate, proxyFn, input, task_name);
                    return @call(.auto, wrapFn, args);
                }

                fn proxyParamless() child.ProxyOut {
                    return proxy(.{});
                }

                fn proxy(varyings: wrap.Varyings) child.ProxyOut {
                    const input: task.In = if (child.inputs.len == 0) .{} else blk: {
                        comptime var shift: usize = 0;
                        var tuple = util.TupleFiller(task.In){};
                        inline for (0..varyings.len) |i| tuple.appendValue(&shift, varyings[i]);
                        inline for (wrap.inputs.len..proxy_inputs.len) |i| tuple.appendValue(&shift, proxy_inputs[i]);
                        break :blk tuple.consume(&shift);
                    };

                    return switch (method) {
                        .sync => proxy_delegate.evaluate(task, input),
                        .asyncd => proxy_delegate.schedule(task, input),
                    };
                }
            };

            // TODO: Overrid support
            return .{
                .name = abst_name ++ " + " ++ task.name,
                .In = child.InvokeInput,
                .Out = wrap.WrapOut,
                .evaluator = &Task.Evaluator{
                    .evalFn = Eval.evaluate,
                    // .overrideFn = override,
                },
                // .meta = &Meta{
                // .ChildFn = child.ChildFn,
                // .childFn = taskFn,
                // .child_inputs = child.inputs,
                // .child_options = options,
                // },
            };
        }

        fn evalArgs(
            comptime InvokeInput: type,
            delegate: *const Delegate,
            proxyFn: wrap.ProxyFn,
            input: InvokeInput,
            task_name: []const u8,
        ) wrap.WrapArgs {
            if (wrap.injects.len + wrap.inputs.len == 0) {
                return .{ delegate, proxyFn };
            } else {
                comptime var shift: usize = 0;

                var tuple = util.TupleFiller(wrap.WrapArgs){};
                tuple.appendValue(&shift, delegate);
                inline for (wrap.injects) |T| {
                    const service = getInjectable(delegate, T, task_name);
                    tuple.appendValue(&shift, service);
                }
                inline for (0..wrap.inputs.len) |i| {
                    tuple.appendValue(&shift, input[i]);
                }
                tuple.appendValue(&shift, proxyFn);
                return tuple.consume(&shift);
            }
        }

        /// A special task, used as a placeholder intended to be overriden.
        /// Evaluating this task without previously providing an implementation will panic.
        pub fn Hook(name: []const u8, comptime input: []const type) Task {
            const invoke_inputs = wrap.invokeInputs(input);
            const InvokeInput: type = if (invoke_inputs.len > 0) std.meta.Tuple(invoke_inputs) else @TypeOf(.{});

            return .{
                .name = name,
                .In = InvokeInput,
                .Out = wrap.WrapOut,
                .evaluator = &Task.Evaluator{
                    .evalFn = tsk.StandardHook(wrap.WrapOut, invoke_inputs).evaluate,
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
            if (task.Out != wrap.ChildOut) @compileError(std.fmt.comptimePrint(
                "Overriding '{s}' expects output type {}",
                .{ task.name, @typeName(task.FnOut) },
            ));

            const meta: *const Meta = @ptrCast(@alignCast(task.meta.?));
            const args: []const type = wrap.varyings ++ meta.child_inputs;

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

            const override_name = name ++ " (overrides '" ++ task.name ++ "')";
            return Define(override_name, taskFn, options);
        }

        pub fn ExtractChildInput(comptime task: Task) type {
            const meta: *const Meta = @ptrCast(@alignCast(task.meta.?));
            return std.meta.Tuple(meta.child_inputs);
        }

        pub fn ExtractChildTask(comptime task: Task) Task {
            const meta: *const Meta = @ptrCast(@alignCast(task.meta.?));
            const taskFn: meta.ChildFn = @ptrCast(@alignCast(meta.childFn));

            const child_name = "[Child] " ++ task.name;
            return tsk.StandardTask(taskFn, meta.child_options).Define(child_name);
        }
    };
}

const WrapMeta = struct {
    ChildOut: type,
    WrapOut: type,
    WrapArgs: type,
    Varyings: type,
    ProxyFn: type,
    injects: []const type,
    varyings: []const type,
    inputs: []const type,

    pub fn from(name: []const u8, comptime wrapFn: anytype, options: AbstractTaskOptions) WrapMeta {
        const wrap_meta = DestructFunc.from(name, wrapFn, options.injects);

        const proxy_meta: ZigType.Fn = proxyMeta(wrap_meta);
        const ChildOut = proxy_meta.return_type.?;
        const wrap_inputs = wrap_meta.inputs[0 .. wrap_meta.inputs.len - 1];

        validateVaryings(wrap_inputs.len, proxy_meta.params, options.varyings);
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

    pub fn invokeInputs(self: WrapMeta, child_inputs: []const type) []const type {
        return if (self.inputs.len + child_inputs.len > 0) self.inputs ++ child_inputs else &.{};
    }

    fn proxyMeta(comptime fn_meta: DestructFunc) ZigType.Fn {
        const input_len = fn_meta.inputs.len;
        if (input_len > 0) switch (@typeInfo(fn_meta.inputs[input_len - 1])) {
            .Pointer => |t| {
                const target = @typeInfo(t.child);
                if (t.size == .One and target == .Fn) return target.Fn;
            },
            else => {},
        };

        @compileError("Abstract task’s last parameter must be a pointer to a function");
    }

    fn validateVaryings(input_len: usize, params: []const ZigType.Fn.Param, varyings: []const type) void {
        if (input_len + varyings.len == 0) {
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
                "Abstract child–invoker is missing varying parameter #{d} of type `{s}`",
                .{ i, @typeName(T) },
            )) else if (T != fields[i].type) @compileError(std.fmt.comptimePrint(
                "Abstract child–invoker’s expects parameter #{d} of type `{s}`",
                .{ i, @typeName(T) },
            ));
        }
    }
};

const ChildMeta = struct {
    ChildFn: type,
    ChildArgs: type,
    InvokeInput: type,
    injects: []const type,
    inputs: []const type,

    pub fn from(
        name: []const u8,
        comptime wrap: WrapMeta,
        comptime childFn: anytype,
        options: Task.Options,
    ) ChildMeta {
        const fn_meta = DestructFunc.from("Abstract '" ++ name ++ "' task", childFn, options.injects);
        validateOutput(wrap.ChildOut, fn_meta.Output, name);
        validateVaryings(wrap.varyings, fn_meta.inputs, 1 + fn_meta.injects.len, name);

        const child_inputs = extractInputs(wrap.varyings, fn_meta.inputs);
        const ChildArgs = Args(wrap.varyings, fn_meta.injects, child_inputs);

        const invoke_inputs = wrap.invokeInputs(child_inputs);
        const InvokeInput: type = if (invoke_inputs.len > 0) std.meta.Tuple(invoke_inputs) else @TypeOf(.{});

        return .{
            .ChildFn = fn_meta.Fn,
            .ChildArgs = ChildArgs,
            .InvokeInput = InvokeInput,
            .injects = fn_meta.injects,
            .inputs = child_inputs,
        };
    }

    fn validateOutput(ChildOut: type, T: type, name: []const u8) void {
        if (T != ChildOut) @compileError(std.fmt.comptimePrint(
            "Abstract '{s}' task expects return type `{s}`",
            .{ name, @typeName(ChildOut) },
        ));
    }

    fn validateVaryings(varyings: []const type, inputs: []const type, param_shift: usize, name: []const u8) void {
        for (varyings, 0..) |T, i| {
            if (i + 1 > inputs.len) @compileError(std.fmt.comptimePrint(
                "Abstract '{s}' task is missing parameter #{d} of type `{s}`",
                .{ name, i + param_shift, @typeName(T) },
            )) else if (T != inputs[i]) @compileError(std.fmt.comptimePrint(
                "Abstract '{s}' task expect parameter #{d} of type `{s}`",
                .{ name, i + param_shift, @typeName(T) },
            ));
        }
    }

    fn extractInputs(varyings: []const type, child_inputs: []const type) []const type {
        return child_inputs[varyings.len..child_inputs.len];
    }

    fn Args(varyings: []const type, child_injects: []const type, child_inputs: []const type) type {
        if (child_injects.len + varyings.len + child_inputs.len == 0) {
            return struct { *const Delegate };
        } else {
            const injects: [child_injects.len]type = child_injects[0..child_injects.len].*;
            return std.meta.Tuple(&[_]type{*const Delegate} ++ injects ++ varyings ++ child_inputs);
        }
    }
};

const ChainMeta = struct {
    ProxyOut: type,
    InvokeInput: type,
    inputs: []const type,

    pub fn from(
        abst_name: []const u8,
        comptime wrap: WrapMeta,
        comptime task: anytype,
        comptime method: AbstractChainMethod,
    ) ChainMeta {
        const ProxyOut = anyerror!Payload(wrap.ChildOut, task, method, abst_name);

        const child_inputs = childInputs(task.In);
        validateChildInputs(wrap.varyings, child_inputs, abst_name, task.name);

        const invoke_inputs = invokeInputs(wrap.varyings, wrap.inputs, child_inputs);
        const InvokeInput: type = if (invoke_inputs.len == 0) @TypeOf(.{}) else std.meta.Tuple(invoke_inputs);

        return .{
            .ProxyOut = ProxyOut,
            .InvokeInput = InvokeInput,
            .inputs = child_inputs,
        };
    }

    fn Payload(
        comptime ChildOut: type,
        comptime task: Task,
        method: AbstractChainMethod,
        abst_name: []const u8,
    ) type {
        const T = switch (@typeInfo(ChildOut)) {
            .ErrorUnion => |t| blk: {
                if (ChildOut != anyerror!t.payload) @compileError(std.fmt.comptimePrint(
                    "Chaining to '{s}' expects the child–invoker to return type `anyerror!{s}`",
                    .{ abst_name, @typeName(t.payload) },
                ));
                break :blk t.payload;
            },
            else => @compileError(std.fmt.comptimePrint(
                "Chaining to '{s}' expects the child–invoker to return an error union",
                .{abst_name},
            )),
        };

        if (T != task.Payload()) @compileError(std.fmt.comptimePrint(
            "Chaining to '{s}' expects output type `{s}` or `anyerror!{1s}`, task '{s}' returns `{s}`",
            .{ abst_name, @typeName(T), task.name, @typeName(task.Out) },
        )) else if (method == .asyncd and T != void) @compileError(std.fmt.comptimePrint(
            "Task '{s}' returns a value, use `.sync` method instead.",
            .{task.name},
        ));

        return T;
    }

    fn childInputs(TaskIn: type) []const type {
        const fields = @typeInfo(TaskIn).Struct.fields;
        if (fields.len == 0) return &.{} else comptime {
            var inputs: [fields.len]type = undefined;
            for (fields, 0..) |f, i| inputs[i] = f.type;
            const static: [fields.len]type = inputs;
            return static[0..fields.len];
        }
    }

    fn validateChildInputs(
        varyings: []const type,
        inputs: []const type,
        abst_name: []const u8,
        task_name: []const u8,
    ) void {
        for (varyings, 0..) |T, i| {
            if (i + 1 > inputs.len or T != inputs[i]) @compileError(std.fmt.comptimePrint(
                "Chaining to '{s}' expects task '{s}' input #{d} of type `{s}`",
                .{ abst_name, task_name, i, @typeName(T) },
            ));
        }
    }

    fn invokeInputs(varyings: []const type, wrap_inputs: []const type, child_inputs: []const type) []const type {
        const vary_len = varyings.len;
        const inp_len = child_inputs.len;
        const invoke_inputs = if (vary_len == inp_len) &.{} else comptime blk: {
            const total_len = inp_len - vary_len;
            var inputs: [total_len]type = undefined;
            for (child_inputs[vary_len..inp_len], 0..) |T, i| inputs[i] = T;
            const static: [total_len]type = inputs;
            break :blk static[0..total_len];
        };

        return if (wrap_inputs.len + invoke_inputs.len == 0) &.{} else wrap_inputs ++ invoke_inputs;
    }
};

test "AbstractTask.Define" {
    tests.did_call = false;
    const Call = tests.AbstractCall.Define("Test Call", tests.callFn, .{});
    Call.evaluate(&tsk.NOOP_DELEGATE, .{});
    try testing.expect(tests.did_call);

    const Varying = tests.AbstractVarying.Define("Test Varying", tests.multiplyFn, .{});
    try testing.expectEqual(108, Varying.evaluate(&tsk.NOOP_DELEGATE, .{ 3, 36 }));
}

test "AbstractTask.Chain" {
    const Chain = tests.AbstractChain.Chain(tests.Multiply, .sync);

    var tester = try PipelineTester.init(.{});
    defer tester.deinit();

    try testing.expectEqual(108, try tester.evaluateSync(Chain, .{ 3, 36 }));
}

test "AbstractTask.ExtractChildInput" {
    const Varying = tests.AbstractVarying.Define("Test Varying", tests.multiplyFn, .{});
    const fields = @typeInfo(tests.AbstractVarying.ExtractChildInput(Varying)).Struct.fields;
    try testing.expectEqual(1, fields.len);
    try testing.expectEqual(usize, fields[0].type);
}

test "AbstractTask.ExtractChildTask" {
    const Varying = tests.AbstractVarying.Define("Test Varying", tests.multiplyFn, .{});
    const ExtractVarying = tests.AbstractVarying.ExtractChildTask(Varying);
    try testing.expectEqual(108, ExtractVarying.evaluate(&tsk.NOOP_DELEGATE, .{ 3, 36 }));
}
