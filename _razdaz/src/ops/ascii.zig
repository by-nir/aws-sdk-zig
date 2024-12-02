const std = @import("std");
const ascii = std.ascii;
const ctrl = std.ascii.control_code;
const lib = @import("../combine.zig");
const Operator = lib.Operator;
const Resolver = lib.Resolver;
const MatchVerdict = lib.Matcher.Verdict;
const testing = @import("../testing.zig");

/// Match any valid ASCII character.
pub const matchValid = Operator.define(ascii.isAscii, .{});

test matchValid {
    try testing.expectEvaluate(matchValid, "\x7F", '\x7F', 1);
    try testing.expectFail(matchValid, "\x80");
}

/// Match a given ASCII character.
pub fn matchChar(comptime char: u8) Operator {
    return Operator.define(struct {
        fn f(c: u8) bool {
            return c == char;
        }
    }.f, .{});
}

test matchChar {
    try testing.expectEvaluate(matchChar('a'), "a", 'a', 1);
    try testing.expectFail(matchChar('x'), "a");
}

/// Match any character other than the given ASCII character.
pub fn unlessChar(comptime char: u8) Operator {
    return Operator.define(struct {
        fn f(c: u8) bool {
            return c != char;
        }
    }.f, .{});
}

test unlessChar {
    try testing.expectEvaluate(unlessChar('x'), "a", 'a', 1);
    try testing.expectFail(unlessChar('a'), "a");
}

/// Match any of the given ASCII characters.
pub fn matchAnyChar(comptime chars: []const u8) Operator {
    return Operator.define(struct {
        fn f(c: u8) bool {
            return isAnyChar(chars, c);
        }
    }.f, .{});
}

test matchAnyChar {
    try testing.expectEvaluate(matchAnyChar("b"), "b", 'b', 1);
    try testing.expectEvaluate(matchAnyChar("ab"), "b", 'b', 1);
    try testing.expectEvaluate(matchAnyChar("abc"), "b", 'b', 1);
    try testing.expectFail(matchAnyChar("abc"), "x");
}

/// Match any character other than the given ASCII characters.
pub fn unlessAnyChar(comptime chars: []const u8) Operator {
    return Operator.define(struct {
        fn f(c: u8) bool {
            return !isAnyChar(chars, c);
        }
    }.f, .{});
}

test unlessAnyChar {
    try testing.expectEvaluate(unlessAnyChar("abc"), "x", 'x', 1);
    try testing.expectFail(unlessAnyChar("abc"), "b");
}

fn isAnyChar(comptime chars: []const u8, c: u8) bool {
    switch (chars.len) {
        0 => @compileError("empty character set"),
        1 => return c == chars[0],
        2 => return c == chars[0] or c == chars[1],
        else => {
            const flags = comptime charFlags(chars);
            const mask = @as(u128, 1) << @intCast(c);
            return (mask & flags) != 0;
        },
    }
}

fn charFlags(chars: []const u8) u128 {
    var flags: u128 = 0;
    for (chars) |c| {
        if (!ascii.isAscii(c)) @compileError(std.fmt.comptimePrint("fond non-ASCII character 0x{X}", .{c}));
        flags |= 1 << c;
    }
    return flags;
}

pub const CharCompound = struct {
    digit: bool = false,
    lowercase: bool = false,
    uppercase: bool = false,
    whitespace: bool = false,
    other: []const u8 = "",
};

/// Match a manually configured character.
pub fn matchCharCompound(comptime compound: CharCompound) Operator {
    if (!compound.lowercase and !compound.uppercase and
        !compound.digit and !compound.whitespace and compound.other.len == 0)
    {
        @compileError("empty charachter compound");
    }

    return Operator.define(struct {
        // `other` may declare a character of a name range while the range isn’t
        // active, so we only consider named ranges for success scenario.
        // For example `.{ .other = "18", .digit = false }`
        fn f(c: u8) bool {
            switch (c) {
                '0'...'9' => if (compound.digit) return true,
                'a'...'z' => if (compound.lowercase) return true,
                'A'...'Z' => if (compound.uppercase) return true,
                ' ', '\t', '\n', '\r' => if (compound.whitespace) return true,
                else => {},
            }

            return compound.other.len > 0 and isAnyChar(compound.other, c);
        }
    }.f, .{});
}

test matchCharCompound {
    try testing.expectEvaluate(matchCharCompound(.{ .digit = true }), "8", '8', 1);
    try testing.expectFail(matchCharCompound(.{ .digit = true }), "x");

    try testing.expectEvaluate(matchCharCompound(.{ .lowercase = true }), "x", 'x', 1);
    try testing.expectFail(matchCharCompound(.{ .lowercase = true }), "8");

    try testing.expectEvaluate(matchCharCompound(.{ .uppercase = true }), "X", 'X', 1);
    try testing.expectFail(matchCharCompound(.{ .uppercase = true }), "8");

    try testing.expectEvaluate(matchCharCompound(.{ .whitespace = true }), " ", ' ', 1);
    try testing.expectFail(matchCharCompound(.{ .whitespace = true }), "x");

    try testing.expectEvaluate(matchCharCompound(.{ .other = "+-@." }), "@", '@', 1);
    try testing.expectFail(matchCharCompound(.{ .other = "+-@." }), "$");

    try testing.expectEvaluate(matchCharCompound(.{ .digit = false, .other = "18" }), "8", '8', 1);
    try testing.expectFail(matchCharCompound(.{ .digit = false, .other = "18" }), "0");
}

/// Match any whitespace character.
pub const matchWhitespace = Operator.define(ascii.isWhitespace, .{});

test matchWhitespace {
    try testing.expectEvaluate(matchWhitespace, " ", ' ', 1);
    try testing.expectEvaluate(matchWhitespace, "\n", '\n', 1);
    try testing.expectEvaluate(matchWhitespace, "\t", '\t', 1);
    try testing.expectEvaluate(matchWhitespace, "\r", '\r', 1);
    try testing.expectFail(matchWhitespace, "x");
}

/// Match any alphabetic ASCII character.
pub const matchAlphabet = Operator.define(ascii.isAlphabetic, .{});

test matchAlphabet {
    try testing.expectEvaluate(matchAlphabet, "x", 'x', 1);
    try testing.expectEvaluate(matchAlphabet, "X", 'X', 1);
    try testing.expectFail(matchAlphabet, "-");
    try testing.expectFail(matchAlphabet, "8");
}

/// Match any alphabetic or digit ASCII character.
pub const matchAlphanum = Operator.define(ascii.isAlphanumeric, .{});

test matchAlphanum {
    try testing.expectEvaluate(matchAlphabet, "x", 'x', 1);
    try testing.expectEvaluate(matchAlphabet, "X", 'X', 1);
    try testing.expectFail(matchAlphabet, "-");
    try testing.expectFail(matchAlphabet, "8");
}

/// Match any digit ASCII character.
pub const matchDigit = Operator.define(ascii.isDigit, .{});

test matchDigit {
    try testing.expectEvaluate(matchDigit, "8", '8', 1);
    try testing.expectFail(matchDigit, "-");
    try testing.expectFail(matchDigit, "x");
}

/// Match any hexadecimal ASCII character. Case-insensitive.
pub const matchHex = Operator.define(ascii.isHex, .{});

test matchHex {
    try testing.expectEvaluate(matchHex, "8", '8', 1);
    try testing.expectEvaluate(matchHex, "f", 'f', 1);
    try testing.expectEvaluate(matchHex, "F", 'F', 1);
    try testing.expectFail(matchHex, "g");
    try testing.expectFail(matchHex, "-");
}

/// Match any lowercase alphabetic ASCII character.
pub const matchLower = Operator.define(ascii.isLower, .{});

test matchLower {
    try testing.expectEvaluate(matchLower, "x", 'x', 1);
    try testing.expectFail(matchLower, "X");
    try testing.expectFail(matchLower, "8");
    try testing.expectFail(matchLower, "-");
}

/// Match any uppercase alphabetic ASCII character.
pub const matchUpper = Operator.define(ascii.isUpper, .{});

test matchUpper {
    try testing.expectEvaluate(matchUpper, "X", 'X', 1);
    try testing.expectFail(matchUpper, "x");
    try testing.expectFail(matchUpper, "8");
    try testing.expectFail(matchUpper, "-");
}

/// Match any ASCII control character.
pub const matchControl = Operator.define(ascii.isControl, .{});

test matchControl {
    try testing.expectEvaluate(matchControl, "\n", '\n', 1);
    try testing.expectFail(matchControl, "x");
    try testing.expectFail(matchControl, "8");
    try testing.expectFail(matchControl, "-");
}

/// Decode an escaped character.
pub const decodeEscape = Operator.define(decodeEscapeMatch, .{
    .scratch_hint = .max(4),
    .resolve = Resolver.define(.fail, decodeEscapeResolve),
});

fn decodeEscapeMatch(i: usize, c: u8) MatchVerdict {
    switch (i) {
        0 => return if (c == '\\') .next else .invalid,
        1 => return switch (c) {
            '\\', '\'', '\"', 'n', 'r', 't', 'b', 'f', 'v' => .done_include,
            'x' => .next,
            else => .invalid,
        },
        2, 3 => return switch (c) {
            '0'...'9', 'a'...'f', 'A'...'F' => if (i == 2) .next else .done_include,
            else => .invalid,
        },
        else => return .done_exclude,
    }
}

fn decodeEscapeResolve(s: []const u8) ?u8 {
    std.debug.assert(s.len > 1);
    std.debug.assert(s[0] == '\\');

    return switch (s[1]) {
        '\\', '\'', '\"' => s[1],
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        'b' => ctrl.bs,
        'f' => ctrl.ff,
        'v' => ctrl.vt,
        'x' => if (s.len != 4) null else std.fmt.parseUnsigned(u8, s[2..4], 16) catch unreachable,
        else => unreachable,
    };
}

test decodeEscape {
    try testing.expectFail(decodeEscape, "aXXXX");
    try testing.expectFail(decodeEscape, "\\aXXX");
    try testing.expectEvaluate(decodeEscape, "\\\\XXX", '\\', 2);
    try testing.expectEvaluate(decodeEscape, "\\'XXX", '\'', 2);
    try testing.expectEvaluate(decodeEscape, "\\\"XXX", '\"', 2);
    try testing.expectEvaluate(decodeEscape, "\\nXXX", '\n', 2);
    try testing.expectEvaluate(decodeEscape, "\\rXXX", '\r', 2);
    try testing.expectEvaluate(decodeEscape, "\\tXXX", '\t', 2);
    try testing.expectEvaluate(decodeEscape, "\\bXXX", ctrl.bs, 2);
    try testing.expectEvaluate(decodeEscape, "\\fXXX", ctrl.ff, 2);
    try testing.expectEvaluate(decodeEscape, "\\vXXX", ctrl.vt, 2);

    try testing.expectFail(decodeEscape, "\\xXXX");
    try testing.expectFail(decodeEscape, "\\xFXX");
    try testing.expectFail(decodeEscape, "\\xFXX");
    try testing.expectEvaluate(decodeEscape, "\\x18X", 0x18, 4);
}

/// Encode an escaped character.
pub const encodeEscape = Operator.define(encodeEscapeMatch, .{
    .resolve = Resolver.define(.fail, encodeEscapeResolve),
});

fn encodeEscapeMatch(c: u8) bool {
    return switch (c) {
        '\\', '\'', '\"', '\n', '\r', '\t' => true,
        else => ascii.isControl(c),
    };
}

fn encodeEscapeResolve(char: u8) ?[]const u8 {
    return switch (char) {
        inline '\\', '\'', '\"' => |c| &.{ '\\', c },
        inline '\n' => "\\n",
        inline '\r' => "\\r",
        inline '\t' => "\\t",
        inline ctrl.bs => "\\b",
        inline ctrl.ff => "\\f",
        inline ctrl.vt => "\\v",
        inline ctrl.nul...ctrl.bel, ctrl.so...ctrl.us, ctrl.del => |c| "\\x" ++ std.fmt.hex(c),
        else => unreachable,
    };
}

test encodeEscape {
    try testing.expectFail(encodeEscape, "a");
    try testing.expectEvaluate(encodeEscape, "\\", "\\\\", 1);
    try testing.expectEvaluate(encodeEscape, "\'", "\\\'", 1);
    try testing.expectEvaluate(encodeEscape, "\"", "\\\"", 1);
    try testing.expectEvaluate(encodeEscape, "\n", "\\n", 1);
    try testing.expectEvaluate(encodeEscape, "\r", "\\r", 1);
    try testing.expectEvaluate(encodeEscape, "\t", "\\t", 1);
    try testing.expectEvaluate(encodeEscape, &.{ctrl.bs}, "\\b", 1);
    try testing.expectEvaluate(encodeEscape, &.{ctrl.ff}, "\\f", 1);
    try testing.expectEvaluate(encodeEscape, &.{ctrl.vt}, "\\v", 1);
    try testing.expectEvaluate(encodeEscape, &.{ctrl.del}, "\\x7f", 1);
}
