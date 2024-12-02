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
    /// Ensure the source’s cursor is aligned prior to evaluating the operator.
    alignment: ?u29 = null,
};

pub const Operator = struct {
    match: Matcher,
    filter: ?Filter = null,
    resolve: ?Resolver = null,
    alignment: ?u29 = null,

    pub fn define(comptime matchFn: anytype, options: OperatorDefine) Operator {
        return .{
            .match = Matcher.define(matchFn, options.scratch_hint),
            .filter = options.filter,
            .resolve = options.resolve,
            .alignment = options.alignment,
        };
    }

    pub fn Input(comptime self: Operator) type {
        return if (self.filter) |filter| filter.operator.Input() else self.match.Input;
    }

    pub fn Output(comptime self: Operator) type {
        const match = self.match;
        return if (self.resolve) |resolve| switch (resolve.behavior) {
            .each_safe, .each_fail => []const resolve.Output,
            else => resolve.Output,
        } else if (match.capacity == .sequence)
            []const match.Input
        else
            match.Input;
    }

    pub fn validate(comptime op: Operator, comptime In: type, comptime Out: ?type) void {
        comptime {
            if (op.Input() != In) @compileError("expects operator input `" ++ @typeName(In) ++ "` (found `" ++ @typeName(op.Input()) ++ "`)");
            if (Out) |O| if (op.Output() != O) @compileError("expects operator output `" ++ @typeName(O) ++ "` (found `" ++ @typeName(op.Output()) ++ "`)");

            const MatchIn = op.match.Input;
            if (op.filter) |f| if (f.operator.Output() != MatchIn)
                @compileError("filter output expects same type `" ++ @typeName(MatchIn) ++ "` (found  `" ++ @typeName(f.operator.Output()) ++ "`)");

            if (op.resolve) |r| {
                var expect_sequence = false;
                var expected_input: ?type = null;
                behave: switch (r.behavior) {
                    .partial, .partial_defer => {
                        expect_sequence = true;
                        expected_input = []const MatchIn;
                    },
                    inline .safe, .each_safe => |_, g| {
                        if (r.Input != r.Output) @compileError("resolver output expects same type as input");
                        continue :behave if (g == .safe) .fail else .each_fail;
                    },
                    .fail => expected_input = if (op.match.capacity == .sequence) []const MatchIn else MatchIn,
                    .each_fail => {
                        expect_sequence = true;
                        expected_input = MatchIn;
                    },
                }

                if (expect_sequence and op.match.capacity != .sequence)
                    @compileError("resolver behavior `." ++ @tagName(r.behavior) ++ "` expects a sequence matcher");

                if (expected_input) |Expected| if (r.Input != Expected)
                    @compileError("resolver input expects type `" ++ @typeName(Expected) ++ "` (found `" ++ @typeName(r.Input) ++ "`)");
            }
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
                    @compileError("single matcher does not expects scratch hints (found `." ++ @tagName(h) ++ "`)");

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
        /// Evaluate the input, otherwise the operation fails.
        fail,
        /// Evaluate the input, otherwise use it as-is.
        fallback,
        /// Evaluate the input and skip matching, otherwise use it as-is.
        override,
        /// Evaluate the input while the filter succeeds.
        validate,
        /// Evaluate the input until the filter succeeds.
        unless,

        pub fn isBreaking(self: Behavior) bool {
            return switch (self) {
                .validate, .unless => true,
                else => false,
            };
        }
    };

    pub fn define(behavior: Behavior, comptime op: Operator) Filter {
        return .{
            .behavior = behavior,
            .operator = op,
        };
    }
};

pub const Resolver = struct {
    Input: type,
    Output: type,
    func: *const anyopaque,
    behavior: Behavior,

    pub const Behavior = union(enum) {
        /// Evaluate the input, otherwise the operation fails.
        fail,
        /// Evaluate the input, otherwise use it as-is.
        safe,
        /// Evaluate the matched input after each sequence iteration.
        /// Success will resolve the operator, otherwise continue matching.
        partial,
        /// Evaluate the matched input starting at the sequence interation of the specified index.
        /// Success will resolve the operator, otherwise continue matching.
        partial_defer: usize,
        /// Evaluate each sequence item, fallback to the source input.
        each_safe,
        /// Evaluate each sequence item, otherwise the operation fails.
        each_fail,

        pub fn isPartial(self: Behavior) bool {
            return switch (self) {
                .partial, .partial_defer => true,
                else => false,
            };
        }

        pub fn isEach(self: Behavior) bool {
            return switch (self) {
                .each_safe, .each_fail => true,
                else => false,
            };
        }
    };

    pub fn Fn(comptime Input: type, comptime Output: type) type {
        return fn (value: Input) ?Output;
    }

    pub fn define(behavior: Behavior, comptime func: anytype) Resolver {
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
            .behavior = behavior,
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
