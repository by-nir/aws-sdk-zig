const transmit = @import("transmit.zig");

pub const Request = transmit.Request;
pub const Client = @import("Client.zig");
pub const Signer = @import("Signer.zig");

const conf_region = @import("config/region.gen.zig");
pub const Region = conf_region.Region;

const conf_settings = @import("config/settings.zig");
pub const SdkConfig = conf_settings.Config;
pub const SdkCredentials = conf_settings.Credentials;

const conf_endpoint = @import("config/endpoint.zig");
const conf_partition = @import("config/partitions.gen.zig");
pub const config = struct {
    pub const Arn = conf_endpoint.Arn;
    pub const Partition = conf_endpoint.Partition;
    pub const isVirtualHostableS3Bucket = conf_endpoint.isVirtualHostableS3Bucket;
    pub const resolvePartition = conf_partition.resolve;
};

test {
    _ = @import("format.zig");
    _ = transmit;
    _ = Signer;
    _ = Client;
    _ = conf_region;
    _ = conf_settings;
    _ = conf_endpoint;
    _ = conf_partition;
}
