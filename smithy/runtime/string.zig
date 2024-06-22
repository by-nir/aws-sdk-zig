const std = @import("std");
const ascii = std.ascii;
const testing = std.testing;

// https://github.com/smithy-lang/smithy-rs/blob/main/rust-runtime/inlineable/src/endpoint_lib/substring.rs
pub fn substring(value: []const u8, start: usize, end: usize, reverse: bool) ![]const u8 {
    if (start >= end) return error.InvalidRange;
    if (end > value.len) return error.RangeOutOfBounds;
    for (value) |c| if (!ascii.isASCII(c)) return error.InvalidAscii;

    return if (reverse)
        value[value.len - end .. value.len - start]
    else
        value[start..end];
}

test "substring" {
    try testing.expectEqualStrings(
        "he",
        try substring("hello", 0, 2, false),
    );
    try testing.expectEqualStrings(
        "hello",
        try substring("hello", 0, 5, false),
    );
    try testing.expectError(
        error.InvalidRange,
        substring("hello", 0, 0, false),
    );
    try testing.expectError(
        error.RangeOutOfBounds,
        substring("hello", 0, 6, false),
    );

    try testing.expectEqualStrings(
        "lo",
        try substring("hello", 0, 2, true),
    );
    try testing.expectEqualStrings(
        "hello",
        try substring("hello", 0, 5, true),
    );
    try testing.expectError(
        error.InvalidRange,
        substring("hello", 0, 0, true),
    );

    try testing.expectError(
        error.InvalidAscii,
        substring("a🐱b", 0, 2, false),
    );
}
