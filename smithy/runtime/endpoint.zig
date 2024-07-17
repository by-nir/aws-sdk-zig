const std = @import("std");
const Allocator = std.mem.Allocator;
const Document = @import("values.zig").Document;
const HttpHeader = @import("http.zig").HttpHeader;

pub const Endpoint = struct {
    url: []const u8,
    headers: []const HttpHeader,
    properties: []const Document.KV,

    pub fn deinit(self: Endpoint, allocator: Allocator) void {
        for (self.properties) |property| property.deinit(allocator);
        for (self.headers) |header| header.deinit(allocator);
        allocator.free(self.properties);
        allocator.free(self.headers);
        allocator.free(self.url);
    }
};
