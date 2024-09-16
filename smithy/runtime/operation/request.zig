const std = @import("std");
const Allocator = std.mem.Allocator;
const Document = @import("document.zig").Document;

pub const HttpHeader = struct {
    key: []const u8,
    values: []const []const u8,

    pub fn deinit(self: HttpHeader, allocator: Allocator) void {
        for (self.values) |value| allocator.free(value);
        allocator.free(self.values);
        allocator.free(self.key);
    }
};

pub const Endpoint = struct {
    url: []const u8,
    headers: []const HttpHeader,
    properties: []const Document.KV,
    auth_schemes: []const AuthScheme,

    pub fn deinit(self: Endpoint, allocator: Allocator) void {
        for (self.auth_schemes) |auth_scheme| auth_scheme.deinit(allocator);
        for (self.properties) |property| property.deinit(allocator);
        for (self.headers) |header| header.deinit(allocator);
        allocator.free(self.auth_schemes);
        allocator.free(self.properties);
        allocator.free(self.headers);
        allocator.free(self.url);
    }
};

pub const AuthScheme = struct {
    id: AuthId,
    properties: []const Document.KV,

    pub fn deinit(self: AuthScheme, allocator: Allocator) void {
        for (self.properties) |property| property.deinit(allocator);
        allocator.free(self.properties);
    }
};

pub const AuthId = enum(u64) {
    none = 0,
    _,

    pub fn of(name: []const u8) AuthId {
        var x: u64 = 0;
        const len = @min(name.len, @sizeOf(@TypeOf(x)));
        @memcpy(std.mem.asBytes(&x)[0..len], name[0..len]);
        return @enumFromInt(x);
    }
};
