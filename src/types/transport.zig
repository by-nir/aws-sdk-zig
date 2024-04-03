const Region = @import("region.zig").Region;

pub const EndpointOptions = struct {
    /// Use a region-specific endpoint
    region: ?Region = null,
    /// Use a scoped virtual host
    virtual_host: ?[]const u8 = null,
    /// Connect through the dual-stack endpoint
    dualstack: bool = false,
    /// Connect through the FIPS endpoint
    fips: bool = false,

    pub fn modifiers(self: EndpointOptions) []const u8 {
        if (!self.dualstack and !self.fips) return "";
        if (self.dualstack and self.fips) return "-fips.dualstack";
        return if (self.dualstack) ".dualstack" else "-fips";
    }
};
