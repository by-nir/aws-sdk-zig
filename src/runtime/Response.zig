//! HTTP response content.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Self = @This();

allocator: Allocator,
status: std.http.Status,
headers: []const u8,
body: []const u8,

pub fn deinit(self: Self) void {
    self.allocator.free(self.headers);
    self.allocator.free(self.body);
}

