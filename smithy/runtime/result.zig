const std = @import("std");

pub fn Result(comptime T: type, comptime E: type) type {
    return union(enum) {
        ok: T,
        fail: Error(E),
    };
}

pub const ErrorSource = enum { client, server };

pub fn Error(comptime Kind: type) type {
    return struct {
        const Self = @This();

        kind: Kind,
        message: ?[]const u8,

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
