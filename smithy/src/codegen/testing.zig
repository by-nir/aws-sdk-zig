const std = @import("std");
pub const allocator = std.testing.allocator;
const Writer = @import("CodegenWriter.zig");

pub fn TestVal(comptime T: type) type {
    return struct {
        expected: []const u8 = "",

        pub fn callback(self: *@This(), value: T) !void {
            defer value.deinit(allocator);
            try Writer.expectValue(self.expected, value);
        }
    };
}

pub fn TestFmt(comptime T: type, comptime format: []const u8) type {
    return struct {
        expected: []const u8 = "",

        pub fn callback(self: *@This(), value: T) !void {
            defer value.deinit(allocator);
            try Writer.expectFmt(self.expected, format, .{value});
        }
    };
}
