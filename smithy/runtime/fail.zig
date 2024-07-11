pub fn Failable(comptime Ok: type, comptime Error: type) type {
    return union(enum) {
        ok: Ok,
        fail: Error,
    };
}

pub const ErrorSource = enum { client, server };
