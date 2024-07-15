const transmit = @import("transmit.zig");

pub const Request = transmit.Request;
pub const Client = @import("Client.zig");
pub const Signer = @import("Signer.zig");

const endpoint = @import("config/endpoint.zig");
const partitions = @import("config/partitions.gen.zig");
const region = @import("config/region.gen.zig");
pub const Region = region.Region;

pub const config = struct {
    pub const Arn = endpoint.Arn;
    pub const Partition = endpoint.Partition;
    pub const isVirtualHostableS3Bucket = endpoint.isVirtualHostableS3Bucket;
    pub const resolvePartition = partitions.resolve;
};

test {
    _ = @import("format.zig");
    _ = transmit;
    _ = Signer;
    _ = Client;
    _ = region;
    _ = endpoint;
    _ = partitions;
}
