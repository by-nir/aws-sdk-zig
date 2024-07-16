const conf_region = @import("config/region.gen.zig");
pub const Region = conf_region.Region;

const conf_settings = @import("config/settings.zig");
pub const SdkConfig = conf_settings.Config;
pub const SdkCredentials = conf_settings.Credentials;

const sign = @import("sign.zig");
const client = @import("client.zig");
const conf_endpoint = @import("config/endpoint.zig");
const conf_partition = @import("config/partitions.gen.zig");
pub const internal = struct {
    pub const Signer = sign.Signer;
    pub const Client = client.Client;
    pub const ClientAction = client.Action;
    pub const ClientRequest = client.Request;
    pub const ClientResponse = client.Response;
    pub const Arn = conf_endpoint.Arn;
    pub const Partition = conf_endpoint.Partition;
    pub const isVirtualHostableS3Bucket = conf_endpoint.isVirtualHostableS3Bucket;
    pub const resolvePartition = conf_partition.resolve;
};

test {
    _ = @import("utils.zig");
    _ = sign;
    _ = client;
    _ = conf_region;
    _ = conf_settings;
    _ = conf_endpoint;
    _ = conf_partition;
}
