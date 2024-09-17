const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ErrorSource = enum {
    client,
    server,
};

pub fn Result(comptime T: type, comptime E: type) type {
    return union(enum) {
        ok: T,
        fail: ResultError(E),

        pub fn deinit(self: @This()) void {
            switch (self) {
                .ok => |t| if (@typeInfo(T) == .@"struct" and @hasDecl(T, "deinit")) t.deinit(),
                .fail => |t| t.deinit(),
            }
        }
    };
}

pub fn ResultError(comptime E: type) type {
    switch (@typeInfo(E)) {
        .@"enum", .@"union" => {},
        else => @compileError("Error type must be an `enum` or `union`"),
    }
    if (!@hasDecl(E, "httpStatus")) @compileError("Error type missing `httpStatus` method");
    if (!@hasDecl(E, "source")) @compileError("Error type missing `source` method");
    if (!@hasDecl(E, "retryable")) @compileError("Error type missing `retryable` method");

    return struct {
        const Self = @This();

        kind: E,
        message: ?[]const u8 = null,
        arena: ?std.heap.ArenaAllocator = null,

        pub fn deinit(self: Self) void {
            if (self.arena) |arena| arena.deinit();
        }

        pub fn httpStatus(self: Self) std.http.Status {
            return self.kind.httpStatus();
        }

        pub fn source(self: Self) ErrorSource {
            return self.kind.source();
        }

        pub fn retryable(self: Self) bool {
            return self.kind.retryable();
        }
    };
}
