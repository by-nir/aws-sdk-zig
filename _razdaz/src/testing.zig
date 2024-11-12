const std = @import("std");
const testing = std.testing;
const test_alloc = testing.allocator;
const lib = @import("combine.zig");
const Filter = lib.Filter;
const Matcher = lib.Matcher;
const Resolver = lib.Resolver;
const Operator = lib.Operator;
const Value = @import("consume/decode.zig").Value;
const Decoder = @import("consume/decode.zig").Decoder;
const Evaluate = @import("consume/evaluate.zig").Evaluate;
const AllocatePref = @import("consume/evaluate.zig").ConsumeBehavior.Allocate;
const TestingReader = @import("consume/read.zig").TestingReader;

pub fn expectEvaluate(
    comptime operator: Operator,
    input: []const operator.Input(),
    value: operator.Output(),
    used: usize,
) !void {
    const T = operator.Output();
    switch (try Evaluate(operator).at(test_alloc, input, .direct_view, 0)) {
        .ok => |state| {
            defer state.deinit(test_alloc);

            if (used != state.used) {
                std.debug.print("expected {} items consumed, found {}\n", .{ used, state.used });
                return error.TestExpectedConsumed;
            }

            switch (T) {
                u8 => try testing.expectEqualStrings(&.{value}, &.{state.value}),
                []const u8 => try testing.expectEqualStrings(value, state.value),
                else => try testing.expectEqualDeep(value, state.value),
            }
        },
        .fail => {
            std.debug.print("expected " ++ valueFormat(T) ++ ", found failed operator\n", .{value});
            return error.TestUnexpectedFail;
        },
        .discard => undefined,
    }
}

pub fn expectFail(comptime operator: Operator, input: []const operator.Input()) !void {
    const T = operator.Output();
    switch (try Evaluate(operator).at(test_alloc, input, .direct_view, 0)) {
        .ok => |state| {
            std.debug.print("expected failed operator, found " ++ valueFormat(T) ++ "\n", .{state.value});
            state.deinit(test_alloc);
        },
        .fail => {},
        .discard => undefined,
    }
}

fn valueFormat(comptime T: type) []const u8 {
    return switch (T) {
        u8 => "'{c}'",
        []const u8 => "\"{s}\"",
        else => "{}",
    };
}

pub fn yieldState(success: bool) Operator {
    return Operator.define(struct {
        fn f(_: u8) bool {
            return success;
        }
    }.f, .{});
}

/// Utility for testing decoders.
pub const TestingDecoder = struct {
    decoder: Decoder(TestingReader) = .{
        .reader = .{},
        .allocator = test_alloc,
    },

    pub fn reset(self: *TestingDecoder, options: TestingReader.ResetOptions) void {
        self.decoder.reader.reset(options);
    }

    pub fn skip(self: *TestingDecoder, operator: TestingOperator) !void {
        return self.decoder.skip(operator.build());
    }

    pub fn peek(
        self: *TestingDecoder,
        operator: TestingOperator,
    ) !Decoder(TestingReader).Peek(operator.build().Output()) {
        return self.decoder.peek(operator.build());
    }

    pub fn take(
        self: *TestingDecoder,
        comptime allocate: AllocatePref,
        operator: TestingOperator,
    ) !Value(operator.build().Output()) {
        return self.decoder.take(allocate, operator.build());
    }

    pub fn expectCursor(self: *TestingDecoder, expected: usize) !void {
        try self.decoder.reader.expectCursor(expected);
    }

    pub fn expectReaderError(_: *TestingDecoder, error_union: anytype) !void {
        try testing.expectError(error.EndOfStream, error_union);
    }

    pub fn expectFailedOperation(_: *TestingDecoder, error_union: anytype) !void {
        try testing.expectError(error.FailedOperation, error_union);
    }
};

pub const TestingOperator = struct {
    matcher: Matcher,
    filter: ?Filter = null,
    resolver: ?Resolver = null,

    pub fn matchSingle(comptime verdict: SingleVerdict) TestingOperator {
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

        return .{ .matcher = Matcher.define(func, null) };
    }

    pub fn matchSequence(comptime verdict: SequenceVerdict, comptime trigger: SequenceTrigger) TestingOperator {
        if (verdict == .next) @compileError("verdict `.next` is not allowed");

        const func = struct {
            fn f(i: usize, c: u8) SequenceVerdict {
                return if (trigger.invoke(i, c)) verdict else .next;
            }
        }.f;

        return .{ .matcher = Matcher.define(func, null) };
    }

    pub fn filterSingle(
        comptime self: *const TestingOperator,
        comptime behavior: Filter.Behavior,
        comptime verdict: SingleVerdict,
        comptime action: ResolveAction,
    ) TestingOperator {
        var b = self.*;
        b.filter = .{
            .behavior = behavior,
            .operator = TestingOperator.matchSingle(verdict).resolve(.fail, action).build(),
        };
        return b;
    }

    pub fn filterSequence(
        comptime self: *const TestingOperator,
        comptime behavior: Filter.Behavior,
        comptime verdict: SequenceVerdict,
        comptime trigger: SequenceTrigger,
        comptime action: ResolveAction,
    ) TestingOperator {
        var b = self.*;
        b.filter = .{
            .behavior = behavior,
            .operator = TestingOperator.matchSequence(verdict, trigger).resolve(.fail, action).build(),
        };
        return b;
    }

    pub fn resolve(
        comptime self: *const TestingOperator,
        comptime behavior: Resolver.Behavior,
        comptime action: ResolveAction,
    ) TestingOperator {
        const In = if (behavior.isEach()) u8 else switch (self.matcher.capacity) {
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
        b.resolver = Resolver.define(behavior, func);
        return b;
    }

    pub fn build(comptime self: TestingOperator) Operator {
        return .{
            .match = self.matcher,
            .filter = self.filter,
            .resolve = self.resolver,
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
        index: usize,
        value: u8,
        unless: u8,

        pub fn invoke(self: SequenceTrigger, i: usize, value: u8) bool {
            return switch (self) {
                .index => |n| n == i,
                .value => |c| c == value,
                .unless => |c| c != value,
            };
        }

        pub fn at(i: usize) SequenceTrigger {
            return .{ .index = i };
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
