const std = @import("std");
const unicode = std.unicode;
const lib = @import("../combine.zig");
const Operator = lib.Operator;
const Resolver = lib.Resolver;
const MatchVerdict = lib.Matcher.Verdict;
const testing = @import("../testing.zig");

/// Match any valid UTF-8 codepoint byte sequence.
pub const matchValid = Operator.define(takeCodepoint, .{
    .scratch_hint = .max(4),
    .resolve = Resolver.define(.fail, struct {
        fn f(input: []const u8) ?[]const u8 {
            const len = unicode.utf8ByteSequenceLength(input[0]) catch undefined;
            return if (len == input.len and unicode.utf8ValidateSlice(input)) input else null;
        }
    }.f),
});

test matchValid {
    try testing.expectEvaluate(matchValid, "abc", "a", 1);
    try testing.expectEvaluate(matchValid, "àbc", "à", 2);
    try testing.expectEvaluate(matchValid, "😀😟", "😀", 4);
    try testing.expectFail(matchValid, "\xF0bc");
}

/// Match a given UTF-8 codepoint byte sequence.
pub fn matchChar(comptime cp: []const u8) Operator {
    const len = unicode.utf8ByteSequenceLength(cp[0]) catch @compileError("invalid codepoint byte sequence");
    if (cp.len != len) @compileError("expects a single codepoint");

    const funcs = struct {
        fn single(_: usize, c: u8) MatchVerdict {
            return if (c == cp[0]) .done_include else .invalid;
        }

        fn multi(i: usize, c: u8) MatchVerdict {
            return if (c == cp[i]) switch (i) {
                0...len - 2 => .next,
                len - 1 => .done_include,
                else => unreachable,
            } else .invalid;
        }
    };

    return Operator.define(switch (len) {
        1 => funcs.single,
        2...4 => funcs.multi,
        else => unreachable,
    }, .{
        .scratch_hint = .count(len),
    });
}

test matchChar {
    try testing.expectEvaluate(matchChar("a"), "abc", "a", 1);
    try testing.expectFail(matchChar("à"), "abc");

    try testing.expectEvaluate(matchChar("à"), "àbc", "à", 2);
    try testing.expectFail(matchChar("a"), "àbc");

    try testing.expectEvaluate(matchChar("😀"), "😀😟", "😀", 4);
    try testing.expectFail(matchChar("😟"), "😀😟");
}

/// Match any codepoint other than the given UTF-8 codepoint byte sequence.
/// Does not validate the matched codepoint is valid UTF-8.
pub fn unlessChar(comptime cp: []const u8) Operator {
    const len = unicode.utf8CountCodepoints(cp) catch @compileError("invalid codepoint byte sequence");
    if (len != 1) @compileError("expects a single codepoint");

    return Operator.define(takeCodepoint, .{
        .scratch_hint = .max(4),
        .resolve = Resolver.define(.fail, struct {
            fn f(input: []const u8) ?[]const u8 {
                return if (std.mem.eql(u8, cp, input)) null else input;
            }
        }.f),
    });
}

test unlessChar {
    try testing.expectEvaluate(unlessChar("a"), "àbc", "à", 2);
    try testing.expectFail(unlessChar("a"), "abc");

    try testing.expectEvaluate(unlessChar("à"), "abc", "a", 1);
    try testing.expectFail(unlessChar("à"), "àbc");

    try testing.expectEvaluate(unlessChar("😟"), "😀😟", "😀", 4);
    try testing.expectFail(unlessChar("😟"), "😟😀");
}

/// Match any of the given UTF-8 codepoints byte sequences.
pub fn matchAnyChar(comptime cps: []const []const u8) Operator {
    const sorted = SortedCodepoints.from(cps);
    return Operator.define(takeCodepointLimit(sorted.max_len), .{
        .scratch_hint = .max(sorted.max_len),
        .resolve = Resolver.define(switch (sorted.min_len) {
            1 => .partial,
            else => .{ .partial_defer = sorted.min_len - 1 },
        }, struct {
            fn f(input: []const u8) ?[]const u8 {
                for (sorted.get(input.len)) |i| {
                    if (std.mem.eql(u8, cps[i], input)) return input;
                } else {
                    return null;
                }
            }
        }.f),
    });
}

test matchAnyChar {
    try testing.expectEvaluate(matchAnyChar(&.{ "a", "à", "😀" }), "abc", "a", 1);
    try testing.expectEvaluate(matchAnyChar(&.{ "a", "à", "😀" }), "àbc", "à", 2);
    try testing.expectEvaluate(matchAnyChar(&.{ "a", "à", "😀" }), "😀bc", "😀", 4);
    try testing.expectFail(matchAnyChar(&.{ "a", "à", "😀" }), "xbc");
}

/// Match any codepoint other than the given UTF-8 codepoints byte sequences.
/// Does not validate the matched codepoint is valid UTF-8.
pub fn unlessAnyChar(comptime cps: []const []const u8) Operator {
    const sorted = SortedCodepoints.from(cps);
    return Operator.define(takeCodepoint, .{
        .scratch_hint = .max(4),
        .resolve = Resolver.define(.fail, struct {
            fn f(input: []const u8) ?[]const u8 {
                for (sorted.get(input.len)) |i| {
                    if (std.mem.eql(u8, cps[i], input)) return null;
                } else {
                    return input;
                }
            }
        }.f),
    });
}

test unlessAnyChar {
    try testing.expectEvaluate(unlessAnyChar(&.{ "a", "à", "😀" }), "xbc", "x", 1);
    try testing.expectEvaluate(unlessAnyChar(&.{ "a", "à", "😀" }), "èbc", "è", 2);
    try testing.expectEvaluate(unlessAnyChar(&.{ "a", "à", "😀" }), "😟bc", "😟", 4);
    try testing.expectFail(unlessAnyChar(&.{ "a", "à", "😀" }), "abc");
    try testing.expectFail(unlessAnyChar(&.{ "a", "à", "😀" }), "àbc");
    try testing.expectFail(unlessAnyChar(&.{ "a", "à", "😀" }), "😀bc");
}

pub const CharCompound = union(enum) {
    codepoint: u21,
    codepoint_bytes: []const u8,
    /// Min/max range, inclusive.
    range_codepoints: [2]u21,
    /// Min/max range, inclusive.
    range_bytes: [2][]const u8,
};

/// Match any of the manually configured UTF-8 codepoints byte sequences.
pub fn matchCharCompound(comptime compound: []const CharCompound) Operator {
    const allow = CompoundCodepoints.from(compound);
    return Operator.define(takeCodepointLimit(allow.max_len), .{
        .scratch_hint = .max(allow.max_len),
        .resolve = Resolver.define(.fail, struct {
            fn f(bytes: []const u8) ?[]const u8 {
                const input = unicode.utf8Decode(bytes) catch return null;
                for (allow.codepoints) |cp| {
                    if (input == cp) return bytes;
                } else for (allow.ranges) |range| {
                    if (input >= range[0] and input <= range[1]) return bytes;
                } else {
                    return null;
                }
            }
        }.f),
    });
}

test matchCharCompound {
    const compund: []const CharCompound = &.{
        .{ .codepoint = '@' },
        .{ .codepoint_bytes = "😀" },
        .{ .range_codepoints = .{ 'a', 'z' } },
        .{ .range_bytes = .{ "א", "ת" } },
    };
    try testing.expectEvaluate(matchCharCompound(compund), "@xx", "@", 1);
    try testing.expectEvaluate(matchCharCompound(compund), "cxx", "c", 1);
    try testing.expectEvaluate(matchCharCompound(compund), "יxx", "י", 2);
    try testing.expectEvaluate(matchCharCompound(compund), "😀xx", "😀", 4);
    try testing.expectFail(matchCharCompound(compund), "Abc");
    try testing.expectFail(matchCharCompound(compund), "àbc");
    try testing.expectFail(matchCharCompound(compund), "ײbc");
    try testing.expectFail(matchCharCompound(compund), "😟bc");
}

/// Match any of the manually configured UTF-8 codepoints byte sequences.
pub fn unlessCharCompound(comptime compound: []const CharCompound) Operator {
    const forbid = CompoundCodepoints.from(compound);
    return Operator.define(takeCodepointLimit(forbid.max_len), .{
        .scratch_hint = .max(forbid.max_len),
        .resolve = Resolver.define(.fail, struct {
            fn f(bytes: []const u8) ?[]const u8 {
                const input = unicode.utf8Decode(bytes) catch return null;
                for (forbid.codepoints) |cp| {
                    if (input == cp) return null;
                } else for (forbid.ranges) |range| {
                    if (input >= range[0] and input <= range[1]) return null;
                } else {
                    return bytes;
                }
            }
        }.f),
    });
}

test unlessCharCompound {
    const compund: []const CharCompound = &.{
        .{ .codepoint = '@' },
        .{ .codepoint_bytes = "😀" },
        .{ .range_codepoints = .{ 'a', 'z' } },
        .{ .range_bytes = .{ "א", "ת" } },
    };
    try testing.expectEvaluate(unlessCharCompound(compund), "$xx", "$", 1);
    try testing.expectEvaluate(unlessCharCompound(compund), "àxx", "à", 2);
    try testing.expectEvaluate(unlessCharCompound(compund), "ײxx", "ײ", 2);
    try testing.expectEvaluate(unlessCharCompound(compund), "😟xx", "😟", 4);
    try testing.expectFail(unlessCharCompound(compund), "@bc");
    try testing.expectFail(unlessCharCompound(compund), "cbc");
    try testing.expectFail(unlessCharCompound(compund), "יbc");
    try testing.expectFail(unlessCharCompound(compund), "😀bc");
}

fn takeCodepoint(i: usize, c: u8) MatchVerdict {
    return switch (i) {
        0 => if (c < 0b10_000000) .done_include else .next,
        1 => if (c >= 0b10_000000 and c < 0b11_000000) .next else .invalid,
        2 => if (c >= 0b10_000000 and c < 0b11_000000) .next else .done_exclude,
        3 => if (c >= 0b10_000000 and c < 0b11_000000) .done_include else .done_exclude,
        else => unreachable,
    };
}

fn takeCodepointLimit(comptime max_len: u3) lib.Matcher.SequenceFn(u8) {
    comptime std.debug.assert(max_len <= 4);
    return struct {
        fn f(i: usize, c: u8) MatchVerdict {
            switch (i) {
                0 => {
                    const fail = comptime if (max_len > 1) .next else .invalid;
                    return if (c < 0b10_000000) .done_include else fail;
                },
                1 => {
                    const success = comptime if (max_len > 2) .next else .done_include;
                    return if (c < 0b10_000000 or c >= 0b11_000000) .invalid else success;
                },
                2 => {
                    const success = comptime if (max_len > 3) .next else .done_include;
                    return if (c < 0b10_000000 or c >= 0b11_000000) .done_exclude else success;
                },
                3 => return if (c >= 0b10_000000 and c < 0b11_000000) .done_include else .done_exclude,
                else => unreachable,
            }
        }
    }.f;
}

const SortedCodepoints = struct {
    min_len: u3,
    max_len: u3,
    indices: [4][]const usize,

    pub fn from(comptime cps: []const []const u8) SortedCodepoints {
        var min: u3 = std.math.maxInt(u3);
        var max: u3 = 0;
        var indices: [4]std.BoundedArray(usize, cps.len) = .{ .{}, .{}, .{}, .{} };
        for (cps, 0..) |cp, i| {
            const len = unicode.utf8ByteSequenceLength(cp[0]) catch @compileError("invalid codepoint byte sequence");
            if (cp.len != len) @compileError("invalid codepoint byte sequence");
            min = @min(min, len);
            max = @max(max, len);
            indices[len - 1].append(i) catch unreachable;
        }

        var all_array: std.BoundedArray(usize, cps.len) = .{};
        for (0..4) |l| all_array.appendSlice(indices[l].constSlice()) catch unreachable;
        const all_slice: [cps.len]usize = all_array.constSlice()[0..cps.len].*;

        var i: usize = 0;
        var sliced: [4][]const usize = .{ &.{}, &.{}, &.{}, &.{} };
        for (0..4) |l| {
            const len = indices[l].len;
            sliced[l] = all_slice[i..][0..len];
            i += len;
        }

        return .{
            .min_len = min,
            .max_len = max,
            .indices = sliced,
        };
    }

    pub fn get(self: SortedCodepoints, len: usize) []const usize {
        return self.indices[len - 1];
    }
};

const CompoundCodepoints = struct {
    min_len: u3,
    max_len: u3,
    ranges: []const [2]u21,
    codepoints: []const u21,

    pub fn from(comptime compound: []const CharCompound) CompoundCodepoints {
        var min: u3 = std.math.maxInt(u3);
        var max: u3 = 0;
        var ranges: std.BoundedArray([2]u21, compound.len) = .{};
        var codepoints: std.BoundedArray(u21, compound.len) = .{};
        for (compound) |entry| {
            switch (entry) {
                .codepoint => |cp| {
                    if (!processCodepoint(cp, &min, &max)) @compileError("invalid codepoint");
                    codepoints.append(cp) catch unreachable;
                },
                .codepoint_bytes => |bytes| {
                    const cp = processBytes(bytes, &min, &max) orelse @compileError("invalid codepoint byte sequence");
                    codepoints.append(cp) catch unreachable;
                },
                .range_codepoints => |range| {
                    const cp_min, const cp_max = range;
                    if (!processCodepoint(cp_min, &min, &max)) @compileError("invalid codepoint");
                    if (!processCodepoint(cp_max, &min, &max)) @compileError("invalid codepoint");
                    ranges.append(range) catch unreachable;
                },
                .range_bytes => |range| {
                    const cp_min = processBytes(range[0], &min, &max) orelse @compileError("invalid codepoint byte sequence");
                    const cp_max = processBytes(range[1], &min, &max) orelse @compileError("invalid codepoint byte sequence");
                    ranges.append(.{ cp_min, cp_max }) catch unreachable;
                },
            }
        }

        const static_ranges: [ranges.len][2]u21 = ranges.constSlice()[0..ranges.len].*;
        const static_codepoints: [codepoints.len]u21 = codepoints.constSlice()[0..codepoints.len].*;

        return .{
            .min_len = min,
            .max_len = max,
            .ranges = &static_ranges,
            .codepoints = &static_codepoints,
        };
    }

    fn processCodepoint(cp: u21, min: *u3, max: *u3) bool {
        if (!unicode.utf8ValidCodepoint(cp)) false;
        const len = unicode.utf8CodepointSequenceLength(cp) catch unreachable;
        min.* = @min(min.*, len);
        max.* = @max(max.*, len);
        return true;
    }

    fn processBytes(bytes: []const u8, min: *u3, max: *u3) ?u21 {
        const cp = unicode.utf8Decode(bytes) catch return null;
        const len = unicode.utf8ByteSequenceLength(bytes[0]) catch unreachable;
        min.* = @min(min.*, len);
        max.* = @max(max.*, len);
        return cp;
    }
};
