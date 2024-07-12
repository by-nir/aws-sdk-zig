const transmit = @import("transmit.zig");

pub const Request = transmit.Request;
pub const Client = @import("Client.zig");
pub const Signer = @import("Signer.zig");

const endpoint = @import("endpoint.zig");
pub const Arn = endpoint.Arn;
pub const Partition = endpoint.Partition;
pub const isVirtualHostableS3Bucket = endpoint.isVirtualHostableS3Bucket;

test {
    _ = @import("format.zig");
    _ = transmit;
    _ = Signer;
    _ = Client;
    _ = endpoint;
}
