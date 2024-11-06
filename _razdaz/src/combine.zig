const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

pub const OperatorDefine = struct {
    filter: ?Filter = null,
    resolve: ?Resolver = null,
};

pub const Operator = struct {
    match: Matcher,
    filter: ?Filter = null,
    resolve: ?Resolver = null,
    /// The expected input size used before resolving.
    scratch_hint: SizeHint,

    pub const SizeHint = union(enum) {
        dynamic,
        bound: usize,
        exact: usize,
    };

    pub fn define(comptime matchFn: anytype, scratch_hint: SizeHint, options: OperatorDefine) Operator {
        return .{
            .match = Matcher.define(matchFn),
            .filter = options.filter,
            .resolve = options.resolve,
            .scratch_hint = scratch_hint,
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

    pub const Capacity = enum {
        single,
        sequence,
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

    pub fn define(comptime func: anytype) Matcher {
        const meta = fnMeta(func);
        const params = meta.params;
        switch (params.len) {
            1 => blk: {
                if (meta.return_type.? != bool) break :blk;
                if (params[0].type.? == void) break :blk;
                return .{
                    .Input = params[0].type.?,
                    .capacity = .single,
                    .func = func,
                };
            },
            2 => blk: {
                if (meta.return_type.? != Verdict) break :blk;
                if (params[0].type.? != usize) break :blk;
                if (params[1].type.? == void) break :blk;
                return .{
                    .Input = params[1].type.?,
                    .capacity = .sequence,
                    .func = func,
                };
            },
            else => {},
        }

        @compileError("expected signature `fn (T) bool` or `fn (usize, T) Matcher.Verdict`");
    }

    pub fn evalSingle(comptime self: Matcher, value: self.Input) bool {
        if (self.capacity != .single) @compileError("Matcher capacity is not single");
        return castFn(SingleFn(self.Input), self.func)(value);
    }

    pub fn evalSequence(comptime self: Matcher, pos: usize, value: self.Input) Verdict {
        if (self.capacity != .sequence) @compileError("Matcher capacity is not sequence");
        return castFn(SequenceFn(self.Input), self.func)(pos, value);
    }
};

pub const Filter = struct {
    behavior: Behavior,
    operator: Operator,

    pub const Behavior = enum {
        /// Evaluate the input, otherwise use the unevaluated input.
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

pub const TestOperator = struct {
    matcher: Matcher,
    filter: ?Filter = null,
    resolver: ?Resolver = null,

    pub fn matchSingle(comptime verdict: SingleVerdict) TestOperator {
        const func = struct {
            fn f(c: u8) bool {
                return switch (verdict) {
                    .ok => true,
                    .fail => false,
                    .fail_value => |v| c != v,
                    .fail_unless => |v| c == v,
                };
            }
        }.f;

        return .{ .matcher = Matcher.define(func) };
    }

    pub fn matchSequence(comptime verdict: SequenceVerdict, comptime trigger: SequenceTrigger) TestOperator {
        if (verdict == .next) @compileError("verdict `.next` is not allowed");

        const func = struct {
            fn f(pos: usize, c: u8) SequenceVerdict {
                return if (trigger.invoke(pos, c)) verdict else .next;
            }
        }.f;

        return .{ .matcher = Matcher.define(func) };
    }

    pub fn filterSingle(
        comptime self: *const TestOperator,
        comptime behavior: Filter.Behavior,
        comptime verdict: SingleVerdict,
        comptime action: ResolveAction,
    ) TestOperator {
        var b = self.*;
        b.filter = .{
            .behavior = behavior,
            .operator = TestOperator.matchSingle(verdict).resolve(action).build(),
        };
        return b;
    }

    pub fn filterSequence(
        comptime self: *const TestOperator,
        comptime behavior: Filter.Behavior,
        comptime verdict: SequenceVerdict,
        comptime trigger: SequenceTrigger,
        comptime action: ResolveAction,
    ) TestOperator {
        var b = self.*;
        b.filter = .{
            .behavior = behavior,
            .operator = TestOperator.matchSequence(verdict, trigger).resolve(action).build(),
        };
        return b;
    }

    pub fn resolve(comptime self: *const TestOperator, comptime action: ResolveAction) TestOperator {
        const In = switch (self.matcher.capacity) {
            .single => u8,
            .sequence => []const u8,
        };

        const Out = switch (action) {
            .fail, .passthrough => In,
            .constant_char => u8,
            .constant_slice => []const u8,
            .count_items => switch (self.match.capacity) {
                .single => unreachable,
                .sequence => usize,
            },
        };

        const func = struct {
            fn f(input: In) ?Out {
                return switch (action) {
                    .fail => null,
                    .passthrough => input,
                    inline .constant_char, .constant_slice => |v| v,
                    .count_items => switch (self.match.capacity) {
                        .single => unreachable,
                        .sequence => input.len,
                    },
                };
            }
        }.f;

        var b = self.*;
        b.resolver = Resolver.define(func);
        return b;
    }

    pub fn build(comptime self: TestOperator) Operator {
        return .{
            .match = self.matcher,
            .filter = self.filter,
            .resolve = self.resolver,
            .scratch_hint = .dynamic,
        };
    }

    pub const SingleVerdict = union(enum) {
        ok,
        fail,
        fail_value: u8,
        fail_unless: u8,
    };

    pub const SequenceVerdict = Matcher.Verdict;

    pub const SequenceTrigger = union(enum) {
        position: usize,
        value: u8,
        unless: u8,

        pub fn invoke(self: SequenceTrigger, pos: usize, value: u8) bool {
            return switch (self) {
                .position => |n| n == pos,
                .value => |c| c == value,
                .unless => |c| c != value,
            };
        }

        pub fn at(pos: usize) SequenceTrigger {
            return .{ .position = pos };
        }

        pub fn eql(value: u8) SequenceTrigger {
            return .{ .value = value };
        }

        pub fn not(value: u8) SequenceTrigger {
            return .{ .unless = value };
        }
    };

    pub const ResolveAction = union(enum) {
        fail,
        passthrough,
        constant_char: u8,
        constant_slice: []const u8,
        count_items,
    };
};
