const std = @import("std");
const lib = @import("../combine.zig");
const Filter = lib.Filter;
const Operator = lib.Operator;
const Resolver = lib.Resolver;
const MatchVerdict = lib.Matcher.Verdict;
const testing = @import("../testing.zig");

/// Negates the operator’s matcher.
/// Does not support sequence matchers.
pub fn not(comptime op: Operator) Operator {
    if (op.match.capacity != .single) @compileError("can’t negate sequence matchers");

    var operator = op;
    operator.match.func = struct {
        fn f(input: op.match.Input) bool {
            return !op.match.evalSingle(input);
        }
    }.f;
    return operator;
}

test not {
    try testing.expectEvaluate(not(testing.yieldState(false)), "a", 'a', 1);
    try testing.expectFail(not(testing.yieldState(true)), "a");
}

/// Apply a filter to a given operator.
/// To override an existing filter, use `overrideFilter` instead.
pub fn withFilter(comptime op: Operator, comptime behavior: Filter.Behavior, comptime filter: Operator) Operator {
    if (op.filter != null) @compileError("filter already exists, use `appendFilter` instead");
    var dupe = op;
    dupe.filter = Filter.define(behavior, filter);
    return dupe;
}

test withFilter {
    try testing.expectEvaluate(withFilter(testing.yieldState(true), .fail, testing.yieldState(true)), "abc", 'a', 1);
    try testing.expectFail(withFilter(testing.yieldState(true), .fail, testing.yieldState(false)), "abc");
}

/// Apply or override a filter for a given operator.
pub fn overrideFilter(comptime op: Operator, comptime behavior: Filter.Behavior, comptime filter: Operator) Operator {
    var dupe = op;
    dupe.filter = Filter.define(behavior, filter);
    return dupe;
}

test overrideFilter {
    try testing.expectEvaluate(overrideFilter(testing.yieldState(true), .fail, testing.yieldState(true)), "abc", 'a', 1);
    try testing.expectFail(overrideFilter(testing.yieldState(true), .fail, testing.yieldState(false)), "abc");
}

/// Apply a resolver to a given operator.
/// To override an existing resolver, use `overrideResolver` instead.
pub fn withResolver(comptime op: Operator, comptime behavior: Resolver.Behavior, comptime func: anytype) Operator {
    if (op.resolve != null) @compileError("resolver already exists, use `appendFilter` instead");
    var dupe = op;
    dupe.resolve = Resolver.define(behavior, func);
    return dupe;
}

test withResolver {
    try testing.expectEvaluate(withResolver(testing.yieldState(true), .fail, testing.resolveState(u8, true)), "abc", 'a', 1);
    try testing.expectFail(withResolver(testing.yieldState(true), .fail, testing.resolveState(u8, false)), "abc");
}

/// Apply or override a resolver for a given operator.
pub fn overrideResolver(comptime op: Operator, comptime behavior: Resolver.Behavior, comptime func: anytype) Operator {
    var dupe = op;
    dupe.resolve = Resolver.define(behavior, func);
    return dupe;
}

test overrideResolver {
    try testing.expectEvaluate(overrideResolver(testing.yieldState(true), .fail, testing.resolveState(u8, true)), "abc", 'a', 1);
    try testing.expectFail(overrideResolver(testing.yieldState(true), .fail, testing.resolveState(u8, false)), "abc");
}
