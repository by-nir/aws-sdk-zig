const lib = @import("../combine.zig");
const Operator = lib.Operator;
const Resolver = lib.Resolver;
const MatchVerdict = lib.Matcher.Verdict;
const testing = @import("../testing.zig");

/// Repeat the operator a specified times.
pub fn repeat(comptime n: usize, comptime op: Operator) Operator {
    const funcs = struct {
        fn match(i: usize, _: op.match.Input) MatchVerdict {
            return if (i == n - 1) .done_include else .next;
        }

        fn resolve(out: []const op.Output()) ?[]const op.Output() {
            return if (out.len == n) out else null;
        }
    };

    return Operator.define(funcs.match, .{
        .filter = .{
            .behavior = .fail,
            .operator = op,
        },
        .scratch_hint = .count(n),
        .resolve = Resolver.define(.fail, funcs.resolve),
    });
}

test repeat {
    try testing.expectEvaluate(repeat(2, testing.yieldState(true)), "abcde", "ab", 2);
    try testing.expectFail(repeat(2, testing.yieldStateChar('b', false)), "abcde");
}

/// Repeat the operator at least the given amount of times.
pub fn repeatMin(comptime min: usize, comptime op: Operator) Operator {
    const funcs = struct {
        fn match(_: usize, _: op.match.Input) MatchVerdict {
            return .next;
        }

        fn resolve(out: []const op.Output()) ?[]const op.Output() {
            return if (out.len < min) null else out;
        }
    };

    return Operator.define(funcs.match, .{
        .filter = .{
            .behavior = .until_fail,
            .operator = op,
        },
        .resolve = Resolver.define(.fail, funcs.resolve),
    });
}

test repeatMin {
    try testing.expectEvaluate(repeatMin(2, testing.yieldStateChar('d', false)), "abcde", "abc", 3);
    try testing.expectEvaluate(repeatMin(2, testing.yieldStateChar('c', false)), "abcde", "ab", 2);
    try testing.expectFail(repeatMin(2, testing.yieldStateChar('b', false)), "abcde");
}

/// Repeat the operator from zero up to the given amount of times.
pub fn repeatMax(comptime max: usize, comptime op: Operator) Operator {
    return Operator.define(struct {
        fn f(i: usize, _: op.match.Input) MatchVerdict {
            return if (i == max - 1) .done_include else .next;
        }
    }.f, .{
        .filter = .{
            .behavior = .until_fail,
            .operator = op,
        },
    });
}

test repeatMax {
    try testing.expectEvaluate(repeatMax(2, testing.yieldStateChar('a', false)), "abcde", "", 0);
    try testing.expectEvaluate(repeatMax(2, testing.yieldStateChar('b', false)), "abcde", "a", 1);
    try testing.expectEvaluate(repeatMax(2, testing.yieldStateChar('c', false)), "abcde", "ab", 2);
}

/// Repeat the operator at least the `min` amount of times and up to `max` amount of times.
pub fn repeatRange(comptime min: usize, comptime max: usize, comptime op: Operator) Operator {
    const funcs = struct {
        fn match(i: usize, _: op.match.Input) MatchVerdict {
            return if (i == max - 1) .done_include else .next;
        }

        fn resolve(out: []const op.Output()) ?[]const op.Output() {
            return if (out.len < min) null else out;
        }
    };

    return Operator.define(funcs.match, .{
        .filter = .{
            .behavior = .until_fail,
            .operator = op,
        },
        .scratch_hint = .max(max),
        .resolve = Resolver.define(.fail, funcs.resolve),
    });
}

test repeatRange {
    try testing.expectEvaluate(repeatRange(2, 3, testing.yieldStateChar('c', false)), "abcde", "ab", 2);
    try testing.expectEvaluate(repeatRange(2, 3, testing.yieldStateChar('d', false)), "abcde", "abc", 3);
    try testing.expectEvaluate(repeatRange(2, 3, testing.yieldStateChar('e', false)), "abcde", "abc", 3);
    try testing.expectFail(repeatRange(2, 3, testing.yieldStateChar('b', false)), "abcde");
}

/// Repeat the operator zero or more times while it’s valid.
pub fn repeatWhile(comptime op: Operator) Operator {
    return Operator.define(struct {
        fn f(_: usize, _: op.match.Input) MatchVerdict {
            return .next;
        }
    }.f, .{
        .filter = .{
            .behavior = .until_fail,
            .operator = op,
        },
    });
}

test repeatWhile {
    try testing.expectEvaluate(repeatWhile(testing.yieldStateChar('a', false)), "abcde", "", 0);
    try testing.expectEvaluate(repeatWhile(testing.yieldStateChar('b', false)), "abcde", "a", 1);
    try testing.expectEvaluate(repeatWhile(testing.yieldStateChar('d', false)), "abcde", "abc", 3);
}
