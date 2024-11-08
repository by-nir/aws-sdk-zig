const std = @import("std");

pub const SizeHint = union(enum) {
    dynamic,
    bound: usize,
    exact: usize,

    pub const one = SizeHint{ .exact = 1 };

    pub fn max(n: usize) SizeHint {
        return .{ .bound = n };
    }

    pub fn count(n: usize) SizeHint {
        return .{ .exact = n };
    }
};

pub const OperatorDefine = struct {
    filter: ?Filter = null,
    resolve: ?Resolver = null,
    /// The expected input size used before resolving.
    scratch_hint: ?SizeHint = null,
};

pub const Operator = struct {
    match: Matcher,
    filter: ?Filter = null,
    resolve: ?Resolver = null,

    pub fn define(comptime matchFn: anytype, options: OperatorDefine) Operator {
        return .{
            .match = Matcher.define(matchFn, options.scratch_hint),
            .filter = options.filter,
            .resolve = options.resolve,
        };
    }

    pub fn Input(comptime self: Operator) type {
        return if (self.filter) |filter| filter.operator.Input() else self.match.Input;
    }

    pub fn Output(comptime self: Operator) type {
        const match = self.match;
        if (self.resolve) |resolve| return resolve.Output;
        return if (match.capacity == .sequence) []const match.Input else match.Input;
    }

    pub fn validate(comptime op: Operator, comptime In: type, comptime Out: ?type) void {
        comptime {
            if (op.Input() != In) @compileError("expects operator input `" ++ In ++ "` (found `" ++ op.Input() ++ "`)");
            if (Out) |O| if (op.Output() != O) @compileError("expects operator output `" ++ O ++ "` (found `" ++ op.Output() ++ "`)");

            if (op.filter) |f| if (f.operator.Output() != op.match.Input)
                @compileError("expects same filter output and matcher input types (found  `" ++ f.operator.Output() ++ "` and `" ++ op.match.Input ++ "`)");

            if (op.resolve) |r| if (r.Input != if (op.match.capacity == .sequence) []const op.match.Input else op.match.Input)
                @compileError("expects same resolver input and matcher input types (found `" ++ r.Input ++ "` and `" ++ op.match.Input ++ "`)");
        }
    }
};

pub const Matcher = struct {
    Input: type,
    capacity: Capacity,
    func: *const anyopaque,

    pub const Capacity = union(enum) {
        single,
        sequence: SizeHint,
    };

    pub const Verdict = enum {
        next,
        done_include,
        done_exclude,
        invalid,
    };

    pub fn SingleFn(comptime T: type) type {
        return fn (value: T) bool;
    }

    pub fn SequenceFn(comptime T: type) type {
        return fn (position: usize, value: T) Verdict;
    }

    pub fn define(comptime func: anytype, scratch_hint: ?SizeHint) Matcher {
        const meta = fnMeta(func);
        const params = meta.params;
        switch (params.len) {
            1 => {
                if (scratch_hint) |h|
                    std.log.warn("single matcher does not expects scratch hints (found `.{s}`)", .{@tagName(h)});

                if (meta.return_type.? == bool and params[0].type.? != void) {
                    return .{
                        .capacity = .single,
                        .Input = params[0].type.?,
                        .func = func,
                    };
                } else @compileError("single matcher expects signature `fn (T) bool`");
            },
            2 => {
                if (meta.return_type.? == Verdict and params[0].type.? == usize and params[1].type.? != void) {
                    return .{
                        .capacity = .{ .sequence = scratch_hint orelse .dynamic },
                        .Input = params[1].type.?,
                        .func = func,
                    };
                } else @compileError("sequence matcher expects signature `fn (usize, T) Matcher.Verdict`");
            },
            else => @compileError("matcher expects signature `fn (T) bool` or `fn (usize, T) Matcher.Verdict`"),
        }
    }

    pub fn evalSingle(comptime self: Matcher, value: self.Input) bool {
        if (self.capacity != .single) @compileError("Matcher capacity is not single");
        return castFn(SingleFn(self.Input), self.func)(value);
    }

    pub fn evalSequence(comptime self: Matcher, i: usize, value: self.Input) Verdict {
        if (self.capacity != .sequence) @compileError("Matcher capacity is not sequence");
        return castFn(SequenceFn(self.Input), self.func)(i, value);
    }
};

pub const Filter = struct {
    behavior: Behavior,
    operator: Operator,

    pub const Behavior = enum {
        /// Evaluate the input, fallback to the source input.
        safe,
        /// Evaluate the input, otherwise the operation fails.
        fail,
        /// Only match the input when evaluating the filter fails.
        skip,
    };
};

pub const Resolver = struct {
    Input: type,
    Output: type,
    func: *const anyopaque,

    pub fn Fn(comptime Input: type, comptime Output: type) type {
        return fn (value: Input) ?Output;
    }

    pub fn define(comptime func: anytype) Resolver {
        const meta = fnMeta(func);

        const Out = blk: {
            if (meta.params.len == 1) switch (@typeInfo(meta.return_type.?)) {
                .optional => |m| break :blk m.child,
                else => {},
            };
            @compileError("expected signature `fn (T0) ?T1`");
        };

        return .{
            .Input = meta.params[0].type.?,
            .Output = Out,
            .func = func,
        };
    }

    pub fn eval(comptime self: Resolver, value: self.Input) ?self.Output {
        return castFn(Fn(self.Input, self.Output), self.func)(value);
    }
};

fn castFn(comptime Fn: type, comptime ptr: *const anyopaque) Fn {
    return @as(*const Fn, @ptrCast(@alignCast(ptr))).*;
}

fn fnMeta(comptime func: anytype) std.builtin.Type.Fn {
    switch (@typeInfo(@TypeOf(func))) {
        .pointer => |m| if (@typeInfo(m.child) == .@"fn" and m.size == .One) return @typeInfo(m.child).@"fn",
        .@"fn" => |m| return m,
        else => {},
    }
    @compileError("expected a function");
}
