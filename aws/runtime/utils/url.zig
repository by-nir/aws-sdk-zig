const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// Applies URI encoding and replaces all reserved characters with their respective %XX code.
///
/// Based on an older Zig implementation:
/// https://github.com/ziglang/zig/blob/4e2570baafb587c679ee0fc5e113ddeb36522a5d/lib/std/Uri.zig
pub fn escapeUri(allocator: Allocator, input: []const u8) Allocator.Error![]u8 {
    var outsize: usize = 0;
    for (input) |c| {
        outsize += if (isUnreserved(c)) @as(usize, 1) else 3;
    }
    var output = try allocator.alloc(u8, outsize);
    var outptr: usize = 0;

    for (input) |c| {
        if (isUnreserved(c)) {
            output[outptr] = c;
            outptr += 1;
        } else {
            var buf: [2]u8 = undefined;
            _ = std.fmt.bufPrint(&buf, "{X:0>2}", .{c}) catch unreachable;

            output[outptr + 0] = '%';
            output[outptr + 1] = buf[0];
            output[outptr + 2] = buf[1];
            outptr += 3;
        }
    }
    return output;
}

/// unreserved  = ALPHA / DIGIT / "-" / "." / "_" / "~"
fn isUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

/// Applies URI encoding and replaces all reserved characters with their respective %XX code.
///
/// Based on an older Zig implementation:
/// https://github.com/ziglang/zig/blob/4e2570baafb587c679ee0fc5e113ddeb36522a5d/lib/std/Uri.zig
pub const UrlEncodeFormat = struct {
    value: []const u8,

    pub fn format(self: UrlEncodeFormat, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        for (self.value) |c| {
            if (isUnreserved(c)) {
                try writer.writeByte(c);
            } else {
                try writer.print("%{X:0>2}", .{c});
            }
        }
    }
};

test UrlEncodeFormat {
    try testing.expectFmt("foo%20bar", "{}", .{UrlEncodeFormat{ .value = "foo bar" }});
}
