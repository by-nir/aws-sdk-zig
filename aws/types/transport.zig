const Region = @import("region.zig").Region;

pub const EndpointOptions = struct {
    /// Use a region-specific endpoint.
    region: EndpointRegion,
    /// Use a scoped virtual host.
    virtual_host: ?[]const u8 = null,
    /// Connect through the dual-stack endpoint.
    dualstack: bool = false,
    /// Connect through the FIPS endpoint.
    fips: bool = false,
    /// Override the service’s default connection preference.
    keep_alive: ?bool = null,

    pub fn modifiers(self: EndpointOptions) []const u8 {
        if (!self.dualstack and !self.fips) return "";
        if (self.dualstack and self.fips) return "-fips.dualstack";
        return if (self.dualstack) ".dualstack" else "-fips";
    }
};

pub const EndpointRegion = union(enum) {
    /// Use a region-specific endpoint.
    region: Region,
    /// Use the shared setting.
    shared,
    /// Use a region-agnostic endpoint.
    global,
};

pub fn Failable(comptime Ok: type, comptime Error: type) type {
    return union(enum) {
        ok: Ok,
        fail: Error,
    };
}

pub const ErrorSource = enum { client, server };
