pub fn Result(comptime T: type, comptime E: type) type {
    return union(enum) {
        ok: T,
        fail: E,
    };
}

pub const ErrorSource = enum { client, server };
