const std = @import("std");
const testing = std.testing;
const ZigType = std.builtin.Type;
const Allocator = std.mem.Allocator;
const util = @import("utils.zig");
const tests = @import("tests.zig");
const tsk = @import("task.zig");
const TaskType = tsk.Task;
const TaskOptions = tsk.Task.Options;
const Delegate = tsk.Delegate;
const DestructFunc = tsk.DestructFunc;
const getInjectable = tsk.getInjectable;
const PipelineTester = @import("pipeline.zig").PipelineTester;

/// Abstract task can’t invoke sub-task as a callback.
pub const InvokeMethod = enum { sync, asyncd };

pub const AbstractOptions = struct {
    /// Services that are provided by the scope.
    injects: []const type = &.{},
    /// Input passed from the wrapper to the child task.
    varyings: []const type = &.{},
};

pub const AbstractTask = struct {
    taskFn: *const fn (name: []const u8, comptime func: anytype, comptime options: TaskOptions) TaskType,
    chainFn: *const fn (comptime task: TaskType, comptime method: InvokeMethod) TaskType,
    abstractFn: *const fn (name: []const u8, comptime func: anytype, comptime options: AbstractOptions) AbstractTask,
    hookFn: *const fn (name: []const u8, comptime input: []const type) TaskType,

    pub fn Define(name: []const u8, comptime func: anytype, comptime options: AbstractOptions) AbstractTask {
        const meta, const ProxyFn = AbstractMeta.fromWrapFn("Abstract task", name, func, options);
        return AbstractFactory(meta, ProxyFn);
    }

    pub fn Task(self: AbstractTask, name: []const u8, comptime func: anytype, comptime options: TaskOptions) TaskType {
        return self.taskFn(name, func, options);
    }

    pub fn Chain(self: AbstractTask, comptime task: TaskType, comptime method: InvokeMethod) TaskType {
        return self.chainFn(task, method);
    }

    pub fn Abstract(self: AbstractTask, name: []const u8, comptime func: anytype, comptime options: AbstractOptions) AbstractTask {
        return self.abstractFn(name, func, options);
    }

    /// A special task, used as a placeholder intended to be overriden.
    /// Evaluating this task without previously providing an implementation will panic.
    pub fn Hook(self: AbstractTask, name: []const u8, comptime input: []const type) TaskType {
        return self.hookFn(name, input);
    }

    pub fn ExtractChildInput(comptime task: TaskType) type {
        const meta: *const OpaqueMeta = @ptrCast(@alignCast(task.meta.?));
        return std.meta.Tuple(meta.child_inputs);
    }

    pub fn ExtractChildTask(comptime task: TaskType) TaskType {
        const meta: *const OpaqueMeta = @ptrCast(@alignCast(task.meta.?));
        return switch (meta.child) {
            .task => |child| child.task,
            .func => |child| blk: {
                const name = "[Child] " ++ task.name;
                const taskFn: child.Fn = @ptrCast(@alignCast(child.func));
                break :blk tsk.StandardTask(taskFn, child.options).Define(name);
            },
        };
    }
};

const OpaqueMeta = struct {
    child_inputs: []const type,
    child: Child,

    pub const Child = union(enum) {
        func: Func,
        task: TaskType,
    };

    pub const Func = struct {
        Fn: type,
        func: *const anyopaque,
        options: TaskOptions,
    };
};

fn AbstractFactory(comptime parent_meta: AbstractMeta, comptime ProxyFn: type) AbstractTask {
    const parent = switch (parent_meta) {
        .wrap_fn => |t| t,
        .mid_fn => |t| t.middle_meta,
        else => unreachable,
    };
    const ProxyOut = @typeInfo(@typeInfo(ProxyFn).Pointer.child).Fn.return_type.?;

    const Factory = struct {
        fn Task(name: []const u8, comptime func: anytype, comptime options: TaskOptions) TaskType {
            const child_meta = AbstractMeta.fromTaskFn(
                "Abstract '" ++ parent.name ++ "' task",
                name,
                func,
                options,
                ProxyOut,
                parent.varyings,
                parent.inputs,
            );
            const child = child_meta.task_fn;

            return .{
                .name = name,
                .In = child.InvokeIn,
                .Out = parent.Out,
                .evaluator = &TaskType.Evaluator{
                    .evalFn = taskEvaluator(ProxyFn, parent_meta, child_meta),
                    .overrideFn = override,
                },
                .meta = &OpaqueMeta{
                    .child_inputs = child.inputs,
                    .child = .{ .func = .{
                        .Fn = child.Fn,
                        .func = child.func,
                        .options = options,
                    } },
                },
            };
        }

        fn Chain(comptime task: TaskType, comptime method: InvokeMethod) TaskType {
            const child_meta = AbstractMeta.fromTaskDef(
                "Chaining to '" ++ parent.name ++ "'",
                task,
                method,
                ProxyOut,
                parent.varyings,
                parent.inputs,
            );
            const child = child_meta.task_def;

            return .{
                .name = parent.name ++ " + " ++ task.name,
                .In = child.InvokeIn,
                .Out = parent.Out,
                .evaluator = &TaskType.Evaluator{
                    .evalFn = taskEvaluator(ProxyFn, parent_meta, child_meta),
                    .overrideFn = override,
                },
                .meta = &OpaqueMeta{
                    .child_inputs = child.inputs,
                    .child = .{ .task = task },
                },
            };
        }

        fn Abstract(name: []const u8, comptime func: anytype, comptime options: AbstractOptions) AbstractTask {
            const meta, const SubProxyFn = AbstractMeta.fromMidFn(
                "Sub-abstract of '" ++ parent.name ++ "'",
                name,
                func,
                options,
                parent_meta,
            );
            return AbstractFactory(meta, SubProxyFn);
        }

        fn Hook(name: []const u8, comptime input: []const type) TaskType {
            const invoke_inputs = parent.inputs ++ input;
            const InvokeIn: type = if (invoke_inputs.len > 0) std.meta.Tuple(invoke_inputs) else struct {};

            return .{
                .name = name,
                .In = InvokeIn,
                .Out = parent.Out,
                .evaluator = &TaskType.Evaluator{
                    .evalFn = tsk.StandardHook(parent.Out, invoke_inputs).evaluate,
                    .overrideFn = override,
                },
                .meta = &OpaqueMeta{
                    .child = undefined,
                    .child_inputs = input,
                },
            };
        }

        pub fn override(
            comptime task: TaskType,
            name: []const u8,
            comptime taskFn: anytype,
            comptime options: TaskOptions,
        ) TaskType {
            const ChildOut = @typeInfo(@typeInfo(ProxyFn).Pointer.child).Fn.return_type.?;

            const fn_meta = DestructFunc.from("Overriding '" ++ task.name ++ "'", taskFn, options.injects);
            if (task.Out != ChildOut) @compileError(std.fmt.comptimePrint(
                "Overriding '{s}' expects output type `{}`",
                .{ task.name, task.FnOut },
            ));

            const meta: *const OpaqueMeta = @ptrCast(@alignCast(task.meta.?));
            const args: []const type = parent.varyings ++ meta.child_inputs;

            const shift = 1 + options.injects.len;
            if (fn_meta.inputs.len + args.len > 0) {
                if (args.len != fn_meta.inputs.len) @compileError(std.fmt.comptimePrint(
                    "Overriding '{s}' expects {d} parameters",
                    .{ task.name, shift + args.len },
                ));

                for (args, 0..) |T, i| {
                    if (T != fn_meta.inputs[i]) @compileError(std.fmt.comptimePrint(
                        "Overriding '{s}' expects parameter #{d} of type `{}`",
                        .{ task.name, shift + i, T },
                    ));
                }
            }

            const override_name = name ++ " (overrides '" ++ task.name ++ "')";
            return Task(override_name, taskFn, options);
        }
    };

    return AbstractTask{
        .taskFn = Factory.Task,
        .chainFn = Factory.Chain,
        .abstractFn = Factory.Abstract,
        .hookFn = Factory.Hook,
    };
}

fn taskEvaluator(
    comptime ProxyFn: type,
    comptime parent_meta: AbstractMeta,
    comptime child_meta: AbstractMeta,
) *const anyopaque {
    const parent = switch (parent_meta) {
        .wrap_fn => |t| t,
        .mid_fn => |t| t.middle_meta,
        else => unreachable,
    };

    const Varyings: type = if (parent.varyings.len > 0) std.meta.Tuple(parent.varyings) else struct {};
    const InvokeIn = switch (child_meta) {
        inline .task_def, .task_fn => |t| t.InvokeIn,
        .mid_fn => |t| t.middle_meta.InvokeIn,
        else => unreachable,
    };

    const Eval = struct {
        threadlocal var proxy_delegate: *const Delegate = undefined;
        threadlocal var proxy_inputs: *const InvokeIn = undefined;

        pub fn evaluate(task_name: []const u8, delegate: *const Delegate, input: InvokeIn) parent.Out {
            proxy_inputs = &input;
            proxy_delegate = delegate;
            const proxyFn: ProxyFn = switch (child_meta) {
                .task_fn => proxyCall,
                .task_def => proxyInvoke,
                else => unreachable,
            };
            const parentFn: parent.Fn = @ptrCast(@alignCast(parent.func));
            const args = if (parent.injects.len + parent.inputs.len == 0)
                .{ delegate, proxyFn }
            else blk: {
                comptime var shift: usize = 0;
                var tuple = util.TupleFiller(parent.Args){};
                tuple.append(&shift, delegate);
                inline for (parent.injects) |T| {
                    const service = getInjectable(&shift, delegate, T, task_name);
                    tuple.append(&shift, service);
                }
                inline for (0..parent.inputs.len) |i| tuple.append(&shift, input[i]);
                tuple.append(&shift, proxyFn);
                break :blk tuple.consume(&shift);
            };
            return @call(.auto, parentFn, args);
        }

        pub fn proxyCall(varyings: Varyings) child_meta.task_fn.Out {
            const child = child_meta.task_fn;
            const childFn: child.Fn = @ptrCast(@alignCast(child.func));

            if (@typeInfo(child.Args).Struct.fields.len == 1) {
                @call(.auto, childFn, .{proxy_delegate});
            } else {
                comptime var shift: usize = 0;
                var tuple = util.TupleFiller(child.Args){};
                tuple.append(&shift, proxy_delegate);
                inline for (child.injects) |T| {
                    const service = getInjectable(proxy_delegate, T, child.name);
                    tuple.append(&shift, service);
                }
                inline for (0..parent.varyings.len) |i| tuple.append(&shift, varyings[i]);
                inline for (parent.inputs.len..proxy_inputs.len) |i| tuple.append(&shift, proxy_inputs[i]);
                const args = tuple.consume(&shift);

                return @call(.auto, childFn, args);
            }
        }

        pub fn proxyInvoke(varyings: Varyings) child_meta.task_def.Out {
            const child = child_meta.task_def;
            const input: child.task.In = if (child.inputs.len == 0) .{} else blk: {
                comptime var shift: usize = 0;
                var tuple = util.TupleFiller(child.task.In){};
                inline for (0..varyings.len) |i| tuple.append(&shift, varyings[i]);
                inline for (parent.inputs.len..proxy_inputs.len) |i| tuple.append(&shift, proxy_inputs[i]);
                break :blk tuple.consume(&shift);
            };

            return switch (child.method) {
                .sync => proxy_delegate.evaluate(child.task, input),
                .asyncd => proxy_delegate.schedule(child.task, input),
            };
        }
    };

    const EvalSubAbstract = struct {
        const actual_parent = parent_meta.mid_fn.parent_meta;
        const ParentVaryings: type = if (parent.varyings.len > 0) std.meta.Tuple(parent.varyings) else struct {};

        threadlocal var proxy_name: []const u8 = undefined;
        threadlocal var proxy_delegate: *const Delegate = undefined;
        threadlocal var proxy_inputs: *const parent.InvokeIn = undefined;

        pub fn evaluate(task_name: []const u8, delegate: *const Delegate, input: parent.InvokeIn) actual_parent.Out {
            proxy_inputs = &input;
            proxy_name = task_name;
            proxy_delegate = delegate;
            const parentFn: actual_parent.Fn = @ptrCast(@alignCast(actual_parent.func));
            const args = if (actual_parent.injects.len + actual_parent.inputs.len == 0)
                .{ delegate, proxyMid }
            else blk: {
                comptime var shift: usize = 0;
                var tuple = util.TupleFiller(actual_parent.Args){};
                tuple.append(&shift, delegate);
                inline for (actual_parent.injects) |T| {
                    const service = getInjectable(&shift, delegate, T, actual_parent.name);
                    tuple.append(&shift, service);
                }
                inline for (0..actual_parent.inputs.len) |i| tuple.append(&shift, input[i]);
                tuple.append(&shift, proxyMid);
                break :blk tuple.consume(&shift);
            };
            return @call(.auto, parentFn, args);
        }

        pub fn proxyMid(varyings: ParentVaryings) parent.Out {
            if (actual_parent.varyings.len + actual_parent.inputs.len == 0) {
                return @call(.auto, Eval.evaluate, .{ proxy_name, proxy_delegate, proxy_inputs.* });
            } else {
                comptime var shift: usize = 0;
                var tuple = util.TupleFiller(InvokeIn){};
                inline for (0..actual_parent.varyings.len) |i| tuple.append(&shift, varyings[i]);
                inline for (actual_parent.inputs.len..proxy_inputs.len) |i| tuple.append(&shift, proxy_inputs[i]);
                const args = tuple.consume(&shift);

                return @call(.auto, Eval.evaluate, .{ proxy_name, proxy_delegate, args });
            }
        }
    };

    return switch (parent_meta) {
        .wrap_fn => Eval.evaluate,
        .mid_fn => EvalSubAbstract.evaluate,
        .task_fn, .task_def => unreachable,
    };
}

const AbstractMeta = union(enum) {
    mid_fn: MidFunc,
    wrap_fn: Func,
    task_fn: Func,
    task_def: Task,

    const MidFunc = struct {
        parent_meta: Func,
        middle_meta: Func,
    };

    const Func = struct {
        name: []const u8,
        Fn: type,
        func: *const anyopaque,
        Args: type,
        InvokeIn: type,
        Out: type,
        inputs: []const type,
        injects: []const type,
        varyings: []const type,
    };

    const Task = struct {
        name: []const u8,
        task: TaskType,
        method: InvokeMethod,
        inputs: []const type,
        Out: type,
        InvokeIn: type,
    };

    pub fn fromWrapFn(
        factory_name: []const u8,
        wrap_name: []const u8,
        comptime func: anytype,
        comptime options: AbstractOptions,
    ) struct { AbstractMeta, type } {
        const fn_meta = DestructFunc.from(factory_name, func, options.injects);

        const proxy_meta: ZigType.Fn = proxyMeta(fn_meta);
        const ChildOut = proxy_meta.return_type.?;
        const inputs = fn_meta.inputs[0 .. fn_meta.inputs.len - 1];

        validateProxyParams(proxy_meta.params, options.varyings);
        const Varyings = if (options.varyings.len == 0) struct {} else std.meta.Tuple(options.varyings);

        const ProxyFn = *const @Type(ZigType{ .Fn = .{
            .calling_convention = .Unspecified,
            .is_generic = false,
            .is_var_args = false,
            .return_type = ChildOut,
            .params = &.{.{ .type = Varyings, .is_generic = false, .is_noalias = false }},
        } });

        const Args = if (inputs.len + options.injects.len == 0)
            struct { *const Delegate, ProxyFn }
        else
            std.meta.Tuple(&[_]type{*const Delegate} ++ options.injects ++ inputs ++ &[_]type{ProxyFn});

        const meta = AbstractMeta{ .wrap_fn = .{
            .name = wrap_name,
            .Fn = fn_meta.Fn,
            .func = func,
            .Args = Args,
            .InvokeIn = void,
            .Out = fn_meta.Out,
            .inputs = inputs,
            .injects = options.injects,
            .varyings = options.varyings,
        } };

        return .{ meta, ProxyFn };
    }

    pub fn fromMidFn(
        factory_name: []const u8,
        mid_name: []const u8,
        comptime func: anytype,
        comptime options: AbstractOptions,
        parent_meta: AbstractMeta,
    ) struct { AbstractMeta, type } {
        const parent = switch (parent_meta) {
            .wrap_fn => |t| t,
            .mid_fn => |t| t.middle_meta,
            else => unreachable,
        };

        const fn_meta = DestructFunc.from(factory_name, func, options.injects);

        const proxy_meta: ZigType.Fn = proxyMeta(fn_meta);
        validateProxyParams(proxy_meta.params, options.varyings);

        const ChildOut = proxy_meta.return_type.?;
        validateChildOutput(ChildOut, fn_meta.Out, factory_name);
        validateChildVaryings(parent.varyings, fn_meta.inputs, 1 + fn_meta.injects.len, factory_name);

        const Args = ChildArgs(&.{}, fn_meta.injects, fn_meta.inputs);
        const Varyings = if (options.varyings.len == 0) struct {} else std.meta.Tuple(options.varyings);
        const SubProxyFn = *const @Type(ZigType{ .Fn = .{
            .calling_convention = .Unspecified,
            .is_generic = false,
            .is_var_args = false,
            .return_type = ChildOut,
            .params = &.{.{ .type = Varyings, .is_generic = false, .is_noalias = false }},
        } });

        const mid_inputs = fn_meta.inputs[0 .. fn_meta.inputs.len - 1];
        const InvokeIn = if (parent.inputs.len + mid_inputs.len == 0)
            struct {}
        else
            std.meta.Tuple(parent.inputs ++ mid_inputs);

        const mid_meta = AbstractMeta{
            .mid_fn = .{
                .parent_meta = parent,
                .middle_meta = .{
                    .name = mid_name,
                    .Fn = fn_meta.Fn,
                    .func = func,
                    .Args = Args,
                    .InvokeIn = InvokeIn,
                    .Out = fn_meta.Out,
                    .inputs = mid_inputs,
                    .injects = options.injects,
                    .varyings = options.varyings,
                },
            },
        };
        return .{ mid_meta, SubProxyFn };
    }

    pub fn fromTaskFn(
        factory_name: []const u8,
        task_name: []const u8,
        comptime func: anytype,
        comptime options: TaskOptions,
        comptime ProxyOut: type,
        comptime parent_varyings: []const type,
        comptime parent_inputs: []const type,
    ) AbstractMeta {
        const fn_meta = DestructFunc.from(factory_name, func, options.injects);
        validateChildOutput(ProxyOut, fn_meta.Out, factory_name);
        validateChildVaryings(parent_varyings, fn_meta.inputs, 1 + fn_meta.injects.len, factory_name);

        const child_inputs = excludeVaryings(parent_varyings, fn_meta.inputs);
        const Args = ChildArgs(parent_varyings, fn_meta.injects, child_inputs);

        const invoke_inputs = taskInvokeInputs(parent_inputs, child_inputs);
        const InvokeIn: type = if (invoke_inputs.len > 0) std.meta.Tuple(invoke_inputs) else struct {};

        return AbstractMeta{ .task_fn = .{
            .name = task_name,
            .Fn = fn_meta.Fn,
            .func = func,
            .Args = Args,
            .InvokeIn = InvokeIn,
            .Out = fn_meta.Out,
            .inputs = child_inputs,
            .injects = fn_meta.injects,
            .varyings = &.{},
        } };
    }

    pub fn fromTaskDef(
        factory_name: []const u8,
        comptime task: TaskType,
        comptime method: InvokeMethod,
        comptime ProxyOut: type,
        comptime parent_varyings: []const type,
        comptime parent_inputs: []const type,
    ) AbstractMeta {
        validateInvokeableProxy(ProxyOut, factory_name);
        validateInvokeOutput(ProxyOut, task.Out, method, factory_name, task.name);
        const Output = util.Failable(task.Out);

        const child_inputs = tupleTypes(task.In);
        validateChainInputs(parent_varyings, child_inputs, factory_name, task.name);

        const invoke_inputs = chainInvokeInputs(parent_varyings, parent_inputs, child_inputs);
        const InvokeInput: type = if (invoke_inputs.len == 0) struct {} else std.meta.Tuple(invoke_inputs);

        const inputs = excludeVaryings(parent_varyings, child_inputs);

        return AbstractMeta{ .task_def = .{
            .name = task.name,
            .task = task,
            .method = method,
            .inputs = inputs,
            .Out = Output,
            .InvokeIn = InvokeInput,
        } };
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

    fn validateProxyParams(params: []const ZigType.Fn.Param, varyings: []const type) void {
        const fields = fld: {
            if (params.len == 1) switch (@typeInfo(params[0].type.?)) {
                .Struct => |t| if (t.fields.len == 0 or t.is_tuple) break :fld t.fields,
                else => {},
            };
            @compileError("Abstract child–invoker expects a single tuple parameter");
        };

        if (fields.len > varyings.len) {
            @compileError("Abstract child–invoker tuple exceeds the options.varyings definition");
        }

        for (varyings, 0..) |T, i| {
            if (fields.len < i + 1) @compileError(std.fmt.comptimePrint(
                "Abstract child–invoker is missing varying parameter #{d} of type `{}`",
                .{ i, T },
            )) else if (T != fields[i].type) @compileError(std.fmt.comptimePrint(
                "Abstract child–invoker’s expects parameter #{d} of type `{}`",
                .{ i, T },
            ));
        }
    }

    fn validateChildOutput(ChildOut: type, T: type, factory_name: []const u8) void {
        if (T != ChildOut) @compileError(std.fmt.comptimePrint(
            "{s} expects return type `{}`",
            .{ factory_name, ChildOut },
        ));
    }

    fn validateChildVaryings(varyings: []const type, inputs: []const type, param_shift: usize, factory_name: []const u8) void {
        for (varyings, 0..) |T, i| {
            if (i + 1 > inputs.len) @compileError(std.fmt.comptimePrint(
                "{s} is missing parameter #{d} of type `{}`",
                .{ factory_name, i + param_shift, T },
            )) else if (T != inputs[i]) @compileError(std.fmt.comptimePrint(
                "{s} expects parameter #{d} of type `{}`",
                .{ factory_name, i + param_shift, T },
            ));
        }
    }

    fn excludeVaryings(varyings: []const type, child_inputs: []const type) []const type {
        return child_inputs[varyings.len..child_inputs.len];
    }

    pub fn taskInvokeInputs(parent_inputs: []const type, child_inputs: []const type) []const type {
        return if (parent_inputs.len + child_inputs.len > 0) parent_inputs ++ child_inputs else &.{};
    }

    fn ChildArgs(varyings: []const type, injects: []const type, inputs: []const type) type {
        if (injects.len + varyings.len + inputs.len == 0) {
            return struct { *const Delegate };
        } else {
            const inj: [injects.len]type = injects[0..injects.len].*;
            return std.meta.Tuple(&[_]type{*const Delegate} ++ inj ++ varyings ++ inputs);
        }
    }

    fn validateInvokeableProxy(comptime Out: type, factory_name: []const u8) void {
        const Payload = util.StripError(Out);
        if (Out == Payload) @compileError(std.fmt.comptimePrint(
            "{s} expects the child–invoker to return an error union",
            .{factory_name},
        )) else if (Out != anyerror!Payload) @compileError(std.fmt.comptimePrint(
            "{s} expects the child–invoker to return type `anyerror!{}`",
            .{ factory_name, Payload },
        ));
    }

    fn validateInvokeOutput(
        comptime ProxuOut: type,
        comptime ChildOut: type,
        comptime method: InvokeMethod,
        factory_name: []const u8,
        child_name: []const u8,
    ) void {
        const ProxyPayload = util.StripError(ProxuOut);
        const ChildPayload = util.StripError(ChildOut);
        if (ProxyPayload != ChildPayload) @compileError(std.fmt.comptimePrint(
            "{s} expects output type `{}` or `anyerror!{1}`, task '{s}' returns `{}`",
            .{ factory_name, ProxyPayload, child_name, ChildOut },
        )) else if (method == .asyncd and ChildPayload != void) @compileError(std.fmt.comptimePrint(
            "Task '{s}' returns a value, use `.sync` method instead.",
            .{child_name},
        ));
    }

    fn tupleTypes(T: type) []const type {
        const fields = @typeInfo(T).Struct.fields;
        if (fields.len == 0) return &.{} else {
            var types: [fields.len]type = undefined;
            inline for (fields, 0..) |f, i| types[i] = f.type;
            const static: [fields.len]type = types;
            return static[0..fields.len];
        }
    }

    fn validateChainInputs(
        varyings: []const type,
        inputs: []const type,
        factory_name: []const u8,
        child_name: []const u8,
    ) void {
        for (varyings, 0..) |T, i| {
            if (i + 1 > inputs.len or T != inputs[i]) @compileError(std.fmt.comptimePrint(
                "{s} expects task '{s}' input #{d} of type `{}`",
                .{ factory_name, child_name, i, T },
            ));
        }
    }

    fn chainInvokeInputs(varyings: []const type, parent_inputs: []const type, child_inputs: []const type) []const type {
        const vary_len = varyings.len;
        const inp_len = child_inputs.len;
        const invoke_inputs = if (vary_len == inp_len) &.{} else comptime blk: {
            const total_len = inp_len - vary_len;
            var inputs: [total_len]type = undefined;
            for (child_inputs[vary_len..inp_len], 0..) |T, i| inputs[i] = T;
            const static: [total_len]type = inputs;
            break :blk static[0..total_len];
        };

        if (parent_inputs.len + invoke_inputs.len == 0)
            return &.{}
        else
            return parent_inputs ++ invoke_inputs;
    }
};

test "AbstractTask .Define and .Task" {
    const CallMult = tests.AbstractCall.Task("Call & Multiply", tests.multiplyFn, .{});

    tests.did_call = false;
    try testing.expectEqual(108, CallMult.evaluate(&tsk.NOOP_DELEGATE, .{ 3, 36 }));
    try testing.expect(tests.did_call);
}

test "AbstractTask.Abstract" {
    const CallAddMult = tests.AbstractCallAdd.Task("Call, Add, and Multiply", tests.multiplyFn, .{});

    tests.did_call = false;
    try testing.expectEqual(108, CallAddMult.evaluate(&tsk.NOOP_DELEGATE, .{ 2, 36 }));
    try testing.expect(tests.did_call);
}

test "AbstractTask.Chain" {
    const Chain = tests.AbstractChain.Chain(tests.Multiply, .sync);

    var tester = try PipelineTester.init(.{});
    defer tester.deinit();

    try testing.expectEqual(108, try tester.evaluateSync(Chain, .{ 3, 36 }));
}

test "AbstractTask.ExtractChildInput" {
    const Varying = tests.AbstractCall.Task("Test Varying", tests.multiplyFn, .{});
    const fields = @typeInfo(AbstractTask.ExtractChildInput(Varying)).Struct.fields;
    try testing.expectEqual(1, fields.len);
    try testing.expectEqual(usize, fields[0].type);
}

test "AbstractTask.ExtractChildTask" {
    const Varying = tests.AbstractCall.Task("Test Varying", tests.multiplyFn, .{});
    const ExtractVarying = AbstractTask.ExtractChildTask(Varying);
    try testing.expectEqual(108, ExtractVarying.evaluate(&tsk.NOOP_DELEGATE, .{ 3, 36 }));
}
