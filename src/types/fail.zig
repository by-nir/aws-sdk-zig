pub fn Failable(comptime Ok: type) type {
    return union(enum) {
        ok: Ok,
        fail: Error,
    };
}

pub const Error = struct {
    type: anyerror,
    code: u16,
    origin: Source,
    retryable: bool,

    pub const Source = enum { client, server };
};
