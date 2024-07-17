const std = @import("std");
const Allocator = std.mem.Allocator;

pub const HttpHeader = struct {
    key: []const u8,
    values: []const []const u8,

    pub fn deinit(self: HttpHeader, allocator: Allocator) void {
        for (self.values) |value| allocator.free(value);
        allocator.free(self.values);
        allocator.free(self.key);
    }
};
