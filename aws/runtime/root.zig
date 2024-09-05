const smithy = @import("smithy");
pub const Set = smithy.Set;
pub const Response = smithy.Response;
pub const ResponseError = smithy.ResponseError;
pub const ErrorSource = smithy.ErrorSource;

const conf_region = @import("config/region.gen.zig");
pub const Region = conf_region.Region;

const conf_settings = @import("config/settings.zig");
pub const SdkConfig = conf_settings.Config;
pub const SdkCredentials = conf_settings.Credentials;

const sign = @import("sign.zig");
const http = @import("http.zig");
const conf_endpoint = @import("config/endpoint.zig");
const conf_partition = @import("config/partitions.gen.zig");
pub const internal = struct {
    pub const Signer = sign.Signer;
    pub const HttpClient = http.Client;
    pub const HttpEvent = http.Event;
    pub const HttpService = http.Service;
    pub const HttpPayload = http.Payload;
    pub const HttpRequest = http.Request;
    pub const HttpResponse = http.Response;
    pub const Arn = conf_endpoint.Arn;
    pub const Partition = conf_endpoint.Partition;
    pub const isVirtualHostableS3Bucket = conf_endpoint.isVirtualHostableS3Bucket;
    pub const resolvePartition = conf_partition.resolve;
};

test {
    _ = @import("utils.zig");
    _ = sign;
    _ = http;
    _ = conf_region;
    _ = conf_settings;
    _ = conf_endpoint;
    _ = conf_partition;
}
