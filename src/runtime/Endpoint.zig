//! Service Endpoint (URI)
//!
//! ```
//! [my-bucket.]s3[-control][-fips][.dualstack][.us-east-1].amazonaws.com
//!  │   service ┘ └ access  └── modifers ───┘  └ region   stack domain ┘
//!  └ virtual host
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const aws = @import("aws-types");
const Region = aws.Region;
const SharedRegion = aws.SharedRegion;
const UserOptions = aws.EndpointOptions;

const Self = @This();

pub const Protocol = enum(u64) { https };

/// Some AWS services offer dual stack endpoints, so that you can access them
/// using either IPv4 or IPv6 requests.
pub const Stack = enum {
    /// Services that offer only dual stack endpoints.
    dual_only,
    /// Services that offer both single and dual stack endpoints.
    dual_or_single,
};

/// Service-level options
pub const ServiceOptions = struct {
    /// Protocal scheme.
    protocol: Protocol,
    /// Service stack support.
    stack: Stack,
    /// Service code.
    name: []const u8,
    /// Sub-service scope.
    access: ?[]const u8 = null,

    fn accessName(comptime self: ServiceOptions) []const u8 {
        return if (self.access) |a| self.name ++ "-" ++ a else self.name;
    }
};

service: []const u8,
region: Region,
scheme: Protocol,
host: []const u8,

pub fn init(allocator: Allocator, comptime service: ServiceOptions, user: UserOptions) !Self {
    const domain: []const u8 = switch (service.stack) {
        .dual_only => ".amazonaws.com",
        .dual_or_single => ".api.aws",
    };

    const name = service.accessName();
    const modifers = user.modifiers();
    var len = name.len + modifers.len + domain.len;
    if (user.virtual_host) |v| len += v.len + 1;

    var region: Region = undefined;
    var hide_region = false;
    switch (user.region) {
        .region => |r| region = r,
        .shared => region = SharedRegion.get(),
        .global => {
            hide_region = true;
            region = Region.sdk_default;
        },
    }
    const region_code: []const u8 = if (!hide_region) blk: {
        const code = region.code();
        len += code.len + 1;
        break :blk code;
    } else undefined;

    var buffer = try std.ArrayListUnmanaged(u8).initCapacity(allocator, len);
    errdefer buffer.deinit(allocator);

    if (user.virtual_host) |v| {
        buffer.appendSliceAssumeCapacity(v);
        buffer.appendAssumeCapacity('.');
    }
    buffer.appendSliceAssumeCapacity(name);
    if (modifers.len > 0) buffer.appendSliceAssumeCapacity(modifers);
    if (!hide_region) {
        buffer.appendAssumeCapacity('.');
        buffer.appendSliceAssumeCapacity(region_code);
    }
    buffer.appendSliceAssumeCapacity(domain);

    return .{
        .service = service.name,
        .region = region,
        .scheme = service.protocol,
        .host = try buffer.toOwnedSlice(allocator),
    };
}

pub fn deinit(self: Self, allocator: Allocator) void {
    allocator.free(self.host);
}

pub fn uri(self: Self) std.Uri {
    return .{
        .scheme = @tagName(self.scheme),
        .host = self.host,
        .path = "/",
    };
}

test "Endpoint" {
    var endpoint = try Self.init(test_alloc, .{
        .protocol = .https,
        .stack = .dual_only,
        .name = "s3",
    }, .{
        .region = .{ .region = .us_west_2 },
        .virtual_host = "my-bucket",
    });
    errdefer endpoint.deinit(test_alloc);
    try testing.expectEqual("s3", endpoint.service);
    try testing.expectEqual(Region.us_west_2, endpoint.region);
    try testing.expectEqualStrings("my-bucket.s3.us-west-2.amazonaws.com", endpoint.host);
    endpoint.deinit(test_alloc);

    endpoint = try Self.init(test_alloc, .{
        .protocol = .https,
        .stack = .dual_or_single,
        .name = "s3",
        .access = "control",
    }, .{
        .region = .global,
        .fips = true,
        .dualstack = true,
    });
    try testing.expectEqual(Region.sdk_default, endpoint.region);
    try testing.expectEqualStrings("s3-control-fips.dualstack.api.aws", endpoint.host);
    try testing.expectEqualDeep(std.Uri{
        .scheme = "https",
        .host = "s3-control-fips.dualstack.api.aws",
        .path = "/",
    }, endpoint.uri());
    endpoint.deinit(test_alloc);
}
