const std = @import("std");
const lib = @import("../combine.zig");
const Operator = lib.Operator;
const Resolver = lib.Resolver;
const MatchVerdict = lib.Matcher.Verdict;
const testing = @import("../testing.zig");

/// Consumes a specified amount of items.
pub fn amount(comptime T: type, n: usize) Operator {
    const funcs = struct {
        fn match(i: usize, _: T) MatchVerdict {
            return if (i == n - 1) .done_include else .next;
        }

        fn resolve(out: []const T) ?[]const T {
            return if (out.len < n) null else out;
        }
    };

    return Operator.define(funcs.match, .{
        .scratch_hint = .count(n),
        .resolve = Resolver.define(.fail, funcs.resolve),
    });
}

test amount {
    try testing.expectEvaluate(amount(u8, 2), "abc", "ab", 2);
}

/// Match a specified slice.
pub fn matchSequence(comptime T: type, comptime value: []const T) Operator {
    const len = value.len;
    return Operator.define(struct {
        fn f(i: usize, c: u8) MatchVerdict {
            switch (len) {
                0 => @compileError("expects a non-empty slice"),
                1 => return switch (i) {
                    0 => if (c == value[0]) .done_include else .invalid,
                    else => unreachable,
                },
                2 => return switch (i) {
                    0 => if (c == value[0]) .next else .invalid,
                    1 => if (c == value[1]) .done_include else .invalid,
                    else => unreachable,
                },
                else => return switch (i) {
                    0...len - 2 => if (c == value[i]) .next else .invalid,
                    len - 1 => if (c == value[len - 1]) .done_include else .invalid,
                    else => unreachable,
                },
            }
        }
    }.f, .{
        .scratch_hint = .count(len),
    });
}

test matchSequence {
    try testing.expectEvaluate(matchSequence(usize, &.{ 0, 1, 2 }), &.{ 0, 1, 2, 3 }, &.{ 0, 1, 2 }, 3);
    try testing.expectFail(matchSequence(usize, &.{ 0, 1, 2 }), &.{ 3, 2, 1 });
}

/// Match a specified string.
pub fn matchString(comptime s: []const u8) Operator {
    return matchSequence(u8, s);
}

test matchString {
    try testing.expectEvaluate(matchString("abc"), "abc0", "abc", 3);
    try testing.expectFail(matchString("abc"), "acb");
}

/// Match any of the specified strings.
pub fn matchAnyString(comptime vals: []const []const u8) Operator {
    for (vals) |s| for (s) |c| {
        if (c <= 127) continue;
        @compileError("string contains non ASCII characters, use `matchSequence` instead");
    };
    if (vals.len == 1) return matchString(vals[0]);

    const min_len, const max_len = blk: {
        var min: usize = std.math.maxInt(usize);
        var max: usize = 0;
        for (vals) |s| {
            if (s.len < min) min = s.len;
            if (s.len > max) max = s.len;
        }
        break :blk .{ min, max };
    };

    const idx_chars = blk: {
        var flags = std.mem.zeroes([max_len]u128);
        for (vals) |s| {
            for (s, 0..) |c, j| flags[j] |= 1 << c;
        }
        break :blk flags;
    };

    const len_indices = blk: {
        var list = std.mem.zeroes([max_len]struct { usize, [vals.len]usize });
        for (vals, 0..) |s, i| {
            const index = list[s.len - 1][0];
            list[s.len - 1][0] += 1;
            list[s.len - 1][1][index] = i;
        }

        var slices: [max_len][]const usize = undefined;
        for (0..max_len) |i| {
            const len, const indices = list[i];
            const slice: [len]usize = indices[0..len].*;
            slices[i] = &slice;
        }
        break :blk slices;
    };

    const funcs = struct {
        fn matchTiny(i: usize, c: u8) MatchVerdict {
            const mask = @as(u128, 1) << @intCast(c);
            if (idx_chars[i] & mask == 0) {
                return .invalid;
            } else {
                return switch (i) {
                    0 => if (max_len > 1) .next else .done_include,
                    1 => .done_include,
                    else => unreachable,
                };
            }
        }

        fn matchMany(i: usize, c: u8) MatchVerdict {
            const mask = @as(u128, 1) << @intCast(c);
            if (idx_chars[i] & mask == 0) {
                return .invalid;
            } else {
                return switch (i) {
                    0...max_len - 2 => .next,
                    max_len - 1 => .done_include,
                    else => unreachable,
                };
            }
        }

        fn resolve(input: []const u8) ?[]const u8 {
            for (len_indices[input.len - 1]) |i| {
                if (std.mem.eql(u8, input, vals[i])) return input;
            }

            return null;
        }
    };

    return Operator.define(switch (max_len) {
        0 => @compileError("expects non-empty strings"),
        1, 2 => funcs.matchTiny,
        else => funcs.matchMany,
    }, .{
        .scratch_hint = .max(max_len),
        .resolve = Resolver.define(.{ .partial_defer = min_len - 1 }, funcs.resolve),
    });
}

test matchAnyString {
    const vals: []const []const u8 = &.{ "abc", "cbade", "xyz" };
    try testing.expectEvaluate(matchAnyString(vals), "abc000", "abc", 3);
    try testing.expectEvaluate(matchAnyString(vals), "xyz000", "xyz", 3);
    try testing.expectEvaluate(matchAnyString(vals), "cbade0", "cbade", 5);
    try testing.expectFail(matchAnyString(vals), "ayc000");

    // Alias `matchString`
    try testing.expectEvaluate(matchAnyString(&.{"abc"}), "abc0", "abc", 3);
}
