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
const UserOptions = @import("aws-types").EndpointOptions;

const Self = @This();

host: []const u8,
scheme: Protocol,

pub fn init(allocator: Allocator, comptime service: ServiceOptions, user: UserOptions) !Self {
    const domain: []const u8 = switch (service.stack) {
        .dual_only => ".amazonaws.com",
        .dual_or_single => ".api.aws",
    };

    const name = service.accessName();
    const modifers = user.modifiers();
    var len = name.len + modifers.len + domain.len;
    if (user.virtual_host) |v| len += v.len + 1;
    const region = if (user.region) |r| blk: {
        const code = r.code();
        len += code.len + 1;
        break :blk code;
    } else null;

    var buffer = try std.ArrayListUnmanaged(u8).initCapacity(allocator, len);
    errdefer buffer.deinit(allocator);

    if (user.virtual_host) |v| {
        buffer.appendSliceAssumeCapacity(v);
        buffer.appendAssumeCapacity('.');
    }
    buffer.appendSliceAssumeCapacity(name);
    if (modifers.len > 0) buffer.appendSliceAssumeCapacity(modifers);
    if (region) |r| {
        buffer.appendAssumeCapacity('.');
        buffer.appendSliceAssumeCapacity(r);
    }
    buffer.appendSliceAssumeCapacity(domain);

    return .{
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
        .path = "",
    };
}

/// Service-level options
pub const ServiceOptions = struct {
    /// Protocal scheme
    protocol: Protocol,
    /// Service stack support
    stack: Stack,
    /// Service code
    name: []const u8,
    /// Sub-service scope
    access: ?[]const u8 = null,

    fn accessName(comptime self: ServiceOptions) []const u8 {
        return if (self.access) |a| self.name ++ "-" ++ a else self.name;
    }
};

pub const Protocol = enum(u64) {
    https,
};

/// Some AWS services offer dual stack endpoints, so that you can access them
/// using either IPv4 or IPv6 requests.
pub const Stack = enum {
    /// Services that offer only dual stack endpoints.
    dual_only,
    /// Services that offer both single and dual stack endpoints.
    dual_or_single,
};

test "Endpoint" {
    var endpoint = try Self.init(test_alloc, .{
        .protocol = .https,
        .stack = .dual_only,
        .name = "s3",
    }, .{
        .region = .us_east_1,
        .virtual_host = "my-bucket",
    });
    errdefer endpoint.deinit(test_alloc);
    try testing.expectEqualStrings("my-bucket.s3.us-east-1.amazonaws.com", endpoint.host);
    endpoint.deinit(test_alloc);

    endpoint = try Self.init(test_alloc, .{
        .protocol = .https,
        .stack = .dual_or_single,
        .name = "s3",
        .access = "control",
    }, .{
        .fips = true,
        .dualstack = true,
    });
    try testing.expectEqualStrings("s3-control-fips.dualstack.api.aws", endpoint.host);
    try testing.expectEqualDeep(std.Uri{
        .scheme = "https",
        .host = "s3-control-fips.dualstack.api.aws",
        .path = "",
    }, endpoint.uri());
    endpoint.deinit(test_alloc);
}
