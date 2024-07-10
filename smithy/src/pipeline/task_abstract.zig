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

pub fn AbstractEval(comptime varyings: []const type, comptime Out: type) type {
    const Varyings: type = std.meta.Tuple(varyings);
    return struct {
        pub const ProxyOut: type = Out;
        pub const proxy_varyings: []const type = varyings;

        ctx: *const anyopaque,
        func: *const fn (*const anyopaque, Varyings) Out,

        pub fn evaluate(self: @This(), in: Varyings) Out {
            return self.func(self.ctx, in);
        }
    };
}

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
        const meta = AbstractMeta.fromWrapFn("Abstract task", name, func, options);
        return AbstractFactory(meta);
    }

    pub fn Task(
        self: AbstractTask,
        name: []const u8,
        comptime func: anytype,
        comptime options: TaskOptions,
    ) TaskType {
        return self.taskFn(name, func, options);
    }

    pub fn Chain(
        self: AbstractTask,
        comptime task: TaskType,
        comptime method: InvokeMethod,
    ) TaskType {
        return self.chainFn(task, method);
    }

    pub fn Abstract(
        self: AbstractTask,
        name: []const u8,
        comptime func: anytype,
        comptime options: AbstractOptions,
    ) AbstractTask {
        return self.abstractFn(name, func, options);
    }

    /// A special task, used as a placeholder intended to be overriden.
    /// Evaluating this task without previously providing an implementation will panic.
    pub fn Hook(self: AbstractTask, name: []const u8, comptime input: []const type) TaskType {
        return self.hookFn(name, input);
    }

    pub fn ExtractChildInput(comptime task: TaskType) type {
        const meta: *const OpaqueMeta = @ptrCast(@alignCast(task.meta.?));
        const inputs = switch (meta.child) {
            inline .task_fn, .task_def => |t| t.inputs,
            else => unreachable,
        };

        return switch (meta.parent) {
            .wrap_fn => std.meta.Tuple(inputs),
            .mid_fn => |parent| std.meta.Tuple(parent.middle_func.inputs ++ inputs),
            else => unreachable,
        };
    }

    pub fn ExtractChildTask(comptime task: TaskType) TaskType {
        const meta: *const OpaqueMeta = @ptrCast(@alignCast(task.meta.?));
        switch (meta.parent) {
            .wrap_fn => switch (meta.child) {
                .task_def => |child| return child.task,
                .task_fn => |child| {
                    const name = "[Extracted] " ++ task.name;
                    const taskFn: child.Fn = @ptrCast(@alignCast(child.func));
                    return tsk.StandardTask(taskFn, meta.options).Define(name);
                },
                else => unreachable,
            },
            .mid_fn => |parent| {
                var func = parent.middle_func;
                func.inputs = parent.parent_func.varyings ++ parent.middle_func.inputs;
                const factory = AbstractFactory(.{ .wrap_fn = .{
                    .func = func,
                    .proxy = parent.middle_proxy,
                } });

                switch (meta.child) {
                    .task_def => |child| return factory.Chain(child.task, child.method),
                    .task_fn => |child| {
                        const name = "[Extracted] " ++ task.name;
                        const taskFn: child.Fn = @ptrCast(@alignCast(child.func));
                        return factory.Task(name, taskFn, meta.options);
                    },
                    else => unreachable,
                }
            },
            else => unreachable,
        }
    }
};

const OpaqueMeta = struct {
    parent: AbstractMeta,
    child: AbstractMeta,
    options: TaskOptions,
};

fn AbstractFactory(comptime parent_meta: AbstractMeta) AbstractTask {
    const parent = switch (parent_meta) {
        .wrap_fn => |t| t.func,
        .mid_fn => |t| t.middle_func,
        else => unreachable,
    };
    const ParentOut = switch (parent_meta) {
        .wrap_fn => |t| t.func.Out,
        .mid_fn => |t| t.parent_func.Out,
        else => unreachable,
    };
    const proxy_meta = switch (parent_meta) {
        .wrap_fn => |t| t.proxy,
        .mid_fn => |t| t.parent_proxy,
        else => unreachable,
    };

    const parent_inputs = switch (parent_meta) {
        .wrap_fn => |t| t.func.inputs,
        .mid_fn => |t| t.parent_func.varyings ++ t.middle_func.inputs,
        else => unreachable,
    };

    const Factory = struct {
        fn Task(name: []const u8, comptime func: anytype, comptime options: TaskOptions) TaskType {
            const child_meta = AbstractMeta.fromTaskFn(
                "Abstract '" ++ parent.name ++ "' task",
                name,
                func,
                options,
                proxy_meta.Out,
                parent.varyings,
                parent_inputs,
            );
            const child = child_meta.task_fn;

            const InvokeIn = switch (parent_meta) {
                .wrap_fn => child.InvokeIn,
                .mid_fn => |t| std.meta.Tuple(t.parent_func.inputs ++ t.middle_func.inputs ++ child.inputs),
                else => unreachable,
            };

            return .{
                .name = name,
                .In = InvokeIn,
                .Out = ParentOut,
                .evaluator = &TaskType.Evaluator{
                    .evalFn = taskEvaluator(parent_meta, child_meta),
                    .overrideFn = override,
                },
                .meta = &OpaqueMeta{
                    .parent = parent_meta,
                    .child = child_meta,
                    .options = options,
                },
            };
        }

        fn Chain(comptime task: TaskType, comptime method: InvokeMethod) TaskType {
            const child_meta = AbstractMeta.fromTaskDef(
                "Chaining to '" ++ parent.name ++ "'",
                task,
                method,
                proxy_meta.Out,
                parent.varyings,
                parent_inputs,
            );
            const child = child_meta.task_def;

            const InvokeIn = switch (parent_meta) {
                .wrap_fn => child.InvokeIn,
                .mid_fn => |t| std.meta.Tuple(t.parent_func.inputs ++ t.middle_func.inputs ++ child.inputs),
                else => unreachable,
            };

            return .{
                .name = parent.name ++ " + " ++ task.name,
                .In = InvokeIn,
                .Out = child.Out,
                .evaluator = &TaskType.Evaluator{
                    .evalFn = taskEvaluator(parent_meta, child_meta),
                    .overrideFn = override,
                },
                .meta = &OpaqueMeta{
                    .parent = parent_meta,
                    .child = child_meta,
                    .options = .{},
                },
            };
        }

        fn Abstract(name: []const u8, comptime func: anytype, comptime options: AbstractOptions) AbstractTask {
            const meta = AbstractMeta.fromMidFn(
                "Sub-abstract of '" ++ parent.name ++ "'",
                name,
                func,
                options,
                parent_meta,
            );
            return AbstractFactory(meta);
        }

        fn Hook(name: []const u8, comptime input: []const type) TaskType {
            const invoke_inputs = parent.inputs ++ input;
            const InvokeIn: type = if (invoke_inputs.len > 0) std.meta.Tuple(invoke_inputs) else struct {};

            return .{
                .name = name,
                .In = InvokeIn,
                .Out = ParentOut,
                .evaluator = &TaskType.Evaluator{
                    .evalFn = tsk.StandardHook(ParentOut, invoke_inputs).evaluate,
                    .overrideFn = override,
                },
                .meta = &OpaqueMeta{
                    .parent = parent_meta,
                    .child = .{ .task_def = .{
                        .name = undefined,
                        .task = undefined,
                        .method = undefined,
                        .inputs = input,
                        .Out = undefined,
                        .InvokeIn = undefined,
                    } },
                    .options = .{},
                },
            };
        }

        pub fn override(
            comptime task: TaskType,
            name: []const u8,
            comptime taskFn: anytype,
            comptime options: TaskOptions,
        ) TaskType {
            if (task.Out != proxy_meta.Out) @compileError(std.fmt.comptimePrint(
                "Overriding '{s}' expects output type `{}`",
                .{ task.name, task.FnOut },
            ));

            const meta: *const OpaqueMeta = @ptrCast(@alignCast(task.meta.?));
            const args: []const type = parent.varyings ++ switch (meta.child) {
                inline .task_fn, .task_def => |t| t.inputs,
                else => unreachable,
            };

            const shift = 1 + options.injects.len;
            const fn_meta = DestructFunc.from("Overriding '" ++ task.name ++ "'", taskFn, options.injects);
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

fn taskEvaluator(comptime parent_meta: AbstractMeta, comptime child_meta: AbstractMeta) *const anyopaque {
    const EvalStandard = struct {
        const meta = parent_meta.wrap_fn;

        const Output = meta.func.Out;
        const Input = switch (child_meta) {
            inline .task_def, .task_fn => |t| t.InvokeIn,
            else => unreachable,
        };

        pub fn evaluate(task_name: []const u8, delegate: *const Delegate, input: Input) Output {
            const parent = meta.func;
            const proxy = meta.proxy;
            const child_eval = resolveChildProxy(Input, proxy, child_meta, parent.inputs.len){
                .delegate = delegate,
                .inputs = input,
            };
            const parentEvalFn = EvalWrapper(Input, proxy.Eval(), parent, parent.inputs.len);
            return parentEvalFn(task_name, delegate, input, child_eval.ref());
        }
    };

    const EvalAbstract = struct {
        const meta = parent_meta.mid_fn;
        const parent_inputs = meta.parent_func.inputs;
        const parent_varyings = meta.middle_func.varyings;
        const mid_inputs = meta.middle_func.inputs;
        const child_inputs = switch (child_meta) {
            inline .task_def, .task_fn => |t| t.inputs,
            else => unreachable,
        };

        const Output = meta.parent_func.Out;
        const invoke_inputs = parent_inputs ++ mid_inputs ++ child_inputs;
        const InvokeInput: type = if (invoke_inputs.len > 0) std.meta.Tuple(invoke_inputs) else @TypeOf(.{});
        const meta_inputs = parent_varyings ++ mid_inputs ++ child_inputs;
        const MetaInput: type = if (meta_inputs.len > 0) std.meta.Tuple(meta_inputs) else @TypeOf(.{});

        pub fn evaluate(task_name: []const u8, delegate: *const Delegate, input: InvokeInput) Output {
            const mid_proxy = meta.middle_proxy;
            const child_skip = parent_inputs.len + mid_inputs.len;
            const eval_child = resolveChildProxy(InvokeInput, mid_proxy, child_meta, child_skip){
                .delegate = delegate,
                .inputs = input,
            };
            const sub_input_len = parent_varyings.len + mid_inputs.len;
            const subEvalFn = EvalWrapper(MetaInput, mid_proxy.Eval(), meta.middle_func, sub_input_len);

            const eval_parent = ProxyMiddle(
                InvokeInput,
                MetaInput,
                mid_proxy.Eval(),
                meta.parent_proxy,
                parent_inputs.len,
            ){
                .task_name = task_name,
                .delegate = delegate,
                .inputs = input,
                .subEvalFn = subEvalFn,
                .eval_child = eval_child.ref(),
            };

            const parentEvalFn = EvalWrapper(InvokeInput, meta.parent_proxy.Eval(), meta.parent_func, parent_inputs.len);
            return parentEvalFn(task_name, delegate, input, eval_parent.ref());
        }
    };

    return switch (parent_meta) {
        .wrap_fn => EvalStandard.evaluate,
        .mid_fn => EvalAbstract.evaluate,
        .task_fn, .task_def => unreachable,
    };
}

fn EvalWrapper(
    comptime Input: type,
    comptime ProxyEval: type,
    comptime parent: AbstractMeta.Func,
    comptime input_len: usize,
) *const fn ([]const u8, *const Delegate, Input, ProxyEval) parent.Out {
    const parentFn: parent.Fn = @ptrCast(@alignCast(parent.func));
    return struct {
        pub fn evaluate(name: []const u8, delegate: *const Delegate, input: Input, proxy_eval: ProxyEval) parent.Out {
            const args = if (parent.injects.len + input_len == 0)
                .{ delegate, proxy_eval }
            else blk: {
                comptime var shift: usize = 0;
                var tuple = util.TupleFiller(parent.Args){};
                tuple.append(&shift, delegate);
                inline for (parent.injects) |T| {
                    const service = getInjectable(&shift, delegate, T, name);
                    tuple.append(&shift, service);
                }
                inline for (0..input_len) |i| tuple.append(&shift, input[i]);
                tuple.append(&shift, proxy_eval);
                break :blk tuple.consume(&shift);
            };
            return @call(.auto, parentFn, args);
        }
    }.evaluate;
}

fn ProxyMiddle(
    comptime InvokeInput: type,
    comptime MetaInput: type,
    comptime ChildProxyEval: type,
    comptime proxy: AbstractMeta.Proxy,
    comptime input_skip: usize,
) type {
    return struct {
        subEvalFn: *const fn ([]const u8, *const Delegate, MetaInput, ChildProxyEval) proxy.Out,
        task_name: []const u8,
        delegate: *const Delegate,
        inputs: InvokeInput,
        eval_child: ChildProxyEval,

        pub fn ref(self: *const @This()) proxy.Eval() {
            return .{
                .ctx = self,
                .func = evaluate,
            };
        }

        pub fn evaluate(ctx: *const anyopaque, varyings: proxy.Varyings()) proxy.Out {
            const self: *const @This() = @ptrCast(@alignCast(ctx));

            comptime var shift: usize = 0;
            var tuple = util.TupleFiller(MetaInput){};
            inline for (0..varyings.len) |i| tuple.append(&shift, varyings[i]);
            inline for (input_skip..self.inputs.len) |i| tuple.append(&shift, self.inputs[i]);
            const child_inputs = tuple.consume(&shift);

            return @call(
                .auto,
                self.subEvalFn,
                .{ self.task_name, self.delegate, child_inputs, self.eval_child },
            );
        }
    };
}

fn resolveChildProxy(
    comptime Input: type,
    comptime proxy: AbstractMeta.Proxy,
    comptime child: AbstractMeta,
    comptime input_skip: usize,
) type {
    return switch (child) {
        .task_fn => |t| ProxyCall(Input, proxy, t, input_skip),
        .task_def => |t| ProxyInvoke(Input, proxy, t, input_skip),
        else => unreachable,
    };
}

fn ProxyCall(
    comptime Input: type,
    comptime proxy: AbstractMeta.Proxy,
    comptime child: AbstractMeta.Func,
    comptime input_skip: usize,
) type {
    return struct {
        delegate: *const Delegate,
        inputs: Input,

        pub fn ref(self: *const @This()) proxy.Eval() {
            return .{
                .ctx = self,
                .func = evaluate,
            };
        }

        pub fn evaluate(ctx: *const anyopaque, varyings: proxy.Varyings()) proxy.Out {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            const childFn: child.Fn = @ptrCast(@alignCast(child.func));

            if (@typeInfo(child.Args).Struct.fields.len == 1) {
                return @call(.auto, childFn, .{self.delegate});
            } else {
                comptime var shift: usize = 0;
                var tuple = util.TupleFiller(child.Args){};
                tuple.append(&shift, self.delegate);
                inline for (child.injects) |T| {
                    const service = getInjectable(self.delegate, T, child.name);
                    tuple.append(&shift, service);
                }
                inline for (0..varyings.len) |i| tuple.append(&shift, varyings[i]);
                inline for (input_skip..self.inputs.len) |i| tuple.append(&shift, self.inputs[i]);
                const args = tuple.consume(&shift);

                return @call(.auto, childFn, args);
            }
        }
    };
}

fn ProxyInvoke(
    comptime Input: type,
    comptime proxy: AbstractMeta.Proxy,
    comptime child: AbstractMeta.Task,
    comptime input_skip: usize,
) type {
    return struct {
        delegate: *const Delegate,
        inputs: Input,

        pub fn ref(self: *const @This()) proxy.Eval() {
            return .{
                .ctx = self,
                .func = evaluate,
            };
        }

        pub fn evaluate(ctx: *const anyopaque, varyings: proxy.Varyings()) proxy.Out {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            const input: child.task.In = if (child.task.In == @TypeOf(.{})) .{} else blk: {
                comptime var shift: usize = 0;
                var tuple = util.TupleFiller(child.task.In){};
                inline for (0..varyings.len) |i| tuple.append(&shift, varyings[i]);
                inline for (input_skip..self.inputs.len) |i| tuple.append(&shift, self.inputs[i]);
                break :blk tuple.consume(&shift);
            };

            return switch (child.method) {
                .sync => self.delegate.evaluate(child.task, input),
                .asyncd => self.delegate.schedule(child.task, input),
            };
        }
    };
}

const AbstractMeta = union(enum) {
    wrap_fn: WrapFunc,
    mid_fn: MidFunc,
    task_fn: Func,
    task_def: Task,

    const WrapFunc = struct {
        func: Func,
        proxy: Proxy,
    };

    const MidFunc = struct {
        parent_func: Func,
        parent_proxy: Proxy,
        middle_func: Func,
        middle_proxy: Proxy,
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

    const Proxy = struct {
        Out: type,
        varyings: []const type,

        pub fn Varyings(comptime self: Proxy) type {
            return if (self.varyings.len == 0) @TypeOf(.{}) else std.meta.Tuple(self.varyings);
        }

        pub fn Eval(comptime self: Proxy) type {
            return AbstractEval(self.varyings, self.Out);
        }

        pub fn validateProxyVaryings(self: Proxy, varyings: []const type) void {
            if (self.varyings.len > varyings.len) {
                @compileError("AbstractEval tuple exceeds the options.varyings definition");
            }

            for (varyings, 0..) |T, i| {
                if (self.varyings.len < i + 1) @compileError(std.fmt.comptimePrint(
                    "AbstractEval is missing varying #{d} of type `{}`",
                    .{ i, T },
                )) else if (T != self.varyings[i]) @compileError(std.fmt.comptimePrint(
                    "AbstractEval expects varying #{d} of type `{}`",
                    .{ i, T },
                ));
            }
        }
    };

    pub fn fromWrapFn(
        factory_name: []const u8,
        wrap_name: []const u8,
        comptime func: anytype,
        comptime options: AbstractOptions,
    ) AbstractMeta {
        const fn_meta = DestructFunc.from(factory_name, func, options.injects);

        const proxy: Proxy = proxyMeta(fn_meta);
        proxy.validateProxyVaryings(options.varyings);
        const inputs = fn_meta.inputs[0 .. fn_meta.inputs.len - 1];

        const Args = if (inputs.len + options.injects.len == 0)
            struct { *const Delegate, proxy.Eval() }
        else
            std.meta.Tuple(&[_]type{*const Delegate} ++ options.injects ++ inputs ++ &[_]type{proxy.Eval()});

        return AbstractMeta{ .wrap_fn = .{
            .func = .{
                .name = wrap_name,
                .Fn = fn_meta.Fn,
                .func = func,
                .Args = Args,
                .InvokeIn = void,
                .Out = fn_meta.Out,
                .inputs = inputs,
                .injects = options.injects,
                .varyings = options.varyings,
            },
            .proxy = proxy,
        } };
    }

    pub fn fromMidFn(
        factory_name: []const u8,
        mid_name: []const u8,
        comptime func: anytype,
        comptime options: AbstractOptions,
        parent_meta: AbstractMeta,
    ) AbstractMeta {
        const parent = parent_meta.wrap_fn.func;
        const fn_meta = DestructFunc.from(factory_name, func, options.injects);

        const proxy: Proxy = proxyMeta(fn_meta);
        proxy.validateProxyVaryings(options.varyings);

        const ChildOut = proxy.Out;
        validateChildOutput(ChildOut, fn_meta.Out, factory_name);
        validateChildVaryings(parent.varyings, fn_meta.inputs, 1 + fn_meta.injects.len, factory_name);

        const Args = ChildArgs(&.{}, fn_meta.injects, fn_meta.inputs);
        const mid_inputs = fn_meta.inputs[0 .. fn_meta.inputs.len - 1];
        const inputs = excludeVaryings(parent.varyings, mid_inputs);

        return AbstractMeta{ .mid_fn = .{
            .parent_func = parent,
            .parent_proxy = parent_meta.wrap_fn.proxy,
            .middle_func = .{
                .name = mid_name,
                .Fn = fn_meta.Fn,
                .func = func,
                .Args = Args,
                .InvokeIn = void,
                .Out = fn_meta.Out,
                .inputs = inputs,
                .injects = options.injects,
                .varyings = options.varyings,
            },
            .middle_proxy = proxy,
        } };
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

        const child_inputs = comptime excludeVaryings(parent_varyings, fn_meta.inputs);
        const Args = ChildArgs(parent_varyings, fn_meta.injects, child_inputs);

        const invoke_inputs = taskInvokeInputs(parent_inputs, child_inputs);
        const InvokeIn: type = if (invoke_inputs.len > 0) std.meta.Tuple(invoke_inputs) else @TypeOf(.{});

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
        const InvokeInput: type = if (invoke_inputs.len == 0) @TypeOf(.{}) else std.meta.Tuple(invoke_inputs);

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

    fn proxyMeta(comptime fn_meta: DestructFunc) Proxy {
        const input_len = fn_meta.inputs.len;
        if (input_len > 0) {
            const T = fn_meta.inputs[input_len - 1];
            if (@typeInfo(T) == .Struct and
                @hasDecl(T, "ProxyOut") and
                @hasDecl(T, "proxy_varyings"))
            {
                return Proxy{
                    .Out = @field(T, "ProxyOut"),
                    .varyings = @field(T, "proxy_varyings"),
                };
            }
        }

        @compileError("Abstract task expects last parameter of type `AbstractEval(varyings, output)`");
    }

    fn validateChildOutput(ChildOut: type, T: type, factory_name: []const u8) void {
        if (T != ChildOut) @compileError(std.fmt.comptimePrint(
            "{s} expects return type `{}`",
            .{ factory_name, ChildOut },
        ));
    }

    fn validateChildVaryings(
        varyings: []const type,
        inputs: []const type,
        param_shift: usize,
        factory_name: []const u8,
    ) void {
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

    pub fn taskInvokeInputs(parent_inputs: []const type, comptime child_inputs: []const type) []const type {
        const child: [child_inputs.len]type = child_inputs[0..child_inputs.len].*;
        return if (parent_inputs.len + child_inputs.len > 0) parent_inputs ++ &child else &.{};
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

    fn chainInvokeInputs(
        varyings: []const type,
        parent_inputs: []const type,
        child_inputs: []const type,
    ) []const type {
        const vary_len = varyings.len;
        const inp_len = child_inputs.len;
        const invoke_inputs: []const type = if (vary_len == inp_len) &.{} else comptime blk: {
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

    try testing.expectEqual(108, try tester.runTask(Chain, .{ 3, 36 }));
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
