//! Service Endpoint (URI)
//!
//! ```
//! [my-bucket.]s3[-control][-fips][.dualstack][.us-east-1].amazonaws.com
//!  │   service ┘ └ access  └── modifers ───┘  └ region   stack domain ┘
//!  └ virtual host
//! ```
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const smithy = @import("smithy/runtime");

/// [Smithy Spec](https://smithy.io/2.0/aws/rules-engine/library-functions.html#partition-structure)
/// [AWS Spec](https://docs.aws.amazon.com/whitepapers/latest/aws-fault-isolation-boundaries/partitions.html)
pub const Partition = struct {
    /// The partition's name.
    name: []const u8,
    /// The partition's default DNS suffix.
    dns_suffix: []const u8,
    /// The partition's dual-stack specific DNS suffix.
    dual_stack_dns_suffix: []const u8,
    /// Indicates whether the partition supports a FIPS compliance mode.
    supports_fips: bool,
    /// Indicates whether the partition supports dual-stack endpoints.
    supports_dual_stack: bool,
    /// The region used by partitional (non-regionalized/global) services for signing.
    implicit_global_region: []const u8,
};

/// [AWS Spec](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference-arns.html)
/// [Smithy Spec](https://smithy.io/2.0/aws/rules-engine/library-functions.html#arn-structure)
pub const Arn = struct {
    allocator: Allocator = undefined,
    /// The partition where the resource is located.
    partition: []const u8 = "",
    /// The service namespace where the resource is located.
    service: []const u8 = "",
    /// The region where the resource is located.
    region: ?[]const u8 = null,
    /// The account that the resource is managed by.
    account_id: ?[]const u8 = null,
    /// A resource id path.
    resource_id: []const []const u8 = &.{},

    // https://github.com/smithy-lang/smithy-rs/blob/main/rust-runtime/inlineable/src/endpoint_lib/arn.rs
    pub fn init(allocator: Allocator, value: []const u8) !Arn {
        var arn = Arn{
            .allocator = allocator,
        };

        var i: usize = 0;
        var it = mem.splitScalar(u8, value, ':');
        var raw_resource_id: []const u8 = undefined;
        while (it.next()) |slice| : (i += 1) {
            switch (i) {
                0 => if (!mem.eql(u8, slice, "arn")) return error.InvalidArn,
                1 => arn.partition = slice,
                2 => arn.service = slice,
                3 => arn.region = if (slice.len > 0) slice else null,
                4 => arn.account_id = if (slice.len > 0) slice else null,
                5 => raw_resource_id = slice,
                // An ID may contain colons as-well
                else => raw_resource_id.len += 1 + slice.len,
            }
        }

        if (i < 6) return error.InvalidArn;

        arn.resource_id = try splitResourceId(allocator, raw_resource_id);
        return arn;
    }

    pub fn deinit(self: Arn) void {
        self.allocator.free(self.resource_id);
    }

    fn splitResourceId(allocator: Allocator, raw: []const u8) ![]const []const u8 {
        var path = std.ArrayList([]const u8).init(allocator);
        errdefer path.deinit();

        var it = mem.splitAny(u8, raw, ":/");
        while (it.next()) |slice| try path.append(slice);

        return try path.toOwnedSlice();
    }

    fn expect(expected: Arn, value: []const u8) !void {
        const url = try Arn.init(expected.allocator, value);
        defer url.deinit();
        try testing.expectEqualDeep(expected, url);
    }
};

test "Arn" {
    try testing.expectError(
        error.InvalidArn,
        Arn.init(test_alloc, "11111111-2222-3333-4444-555555555555"),
    );
    try testing.expectError(
        error.InvalidArn,
        Arn.init(test_alloc, "arn:aws:sns"),
    );

    try Arn.expect(.{
        .allocator = test_alloc,
        .partition = "aws",
        .service = "sns",
        .region = "us-west-2",
        .account_id = "012345678910",
        .resource_id = &.{"example-sns-topic-name"},
    }, "arn:aws:sns:us-west-2:012345678910:example-sns-topic-name");

    try Arn.expect(.{
        .allocator = test_alloc,
        .partition = "aws",
        .service = "ec2",
        .region = "us-east-1",
        .account_id = "012345678910",
        .resource_id = &.{ "vpc", "vpc-0e9801d129EXAMPLE" },
    }, "arn:aws:ec2:us-east-1:012345678910:vpc/vpc-0e9801d129EXAMPLE");

    try Arn.expect(.{
        .allocator = test_alloc,
        .partition = "aws",
        .service = "iam",
        .region = null,
        .account_id = "012345678910",
        .resource_id = &.{ "user", "johndoe" },
    }, "arn:aws:iam::012345678910:user/johndoe");

    try Arn.expect(.{
        .allocator = test_alloc,
        .partition = "aws",
        .service = "s3",
        .region = null,
        .account_id = null,
        .resource_id = &.{ "foo", "bucket_name" },
    }, "arn:aws:s3:::foo:bucket_name");
}

// https://github.com/smithy-lang/smithy-rs/blob/main/rust-runtime/inlineable/src/endpoint_lib/s3.rs
pub fn isVirtualHostableS3Bucket(label: []const u8, allow_subdomains: bool) bool {
    if (!smithy.internal.isValidHostLabel(label, allow_subdomains)) return false;
    if (allow_subdomains) {
        var it = mem.splitScalar(u8, label, '.');
        while (it.next()) |part| {
            if (!isVirtualHostableSegment(part)) return false;
        }
        return true;
    } else {
        return isVirtualHostableSegment(label);
    }
}

fn isVirtualHostableSegment(label: []const u8) bool {
    if (!std.ascii.isAlphanumeric(label[0])) return false;
    if (!std.ascii.isAlphanumeric(label[label.len - 1])) return false;
    if (std.net.Ip4Address.parse(label, 0)) |_| return false else |_| {}
    if (mem.indexOf(u8, label, ".-")) |_| return false;
    if (mem.indexOf(u8, label, "-.")) |_| return false;
    return true;
}

test "isVirtualHostableS3Bucket" {
    try testing.expect(isVirtualHostableS3Bucket("a--b--x-s3", false));
    try testing.expect(!isVirtualHostableS3Bucket("a-.b-.c", true));
}
