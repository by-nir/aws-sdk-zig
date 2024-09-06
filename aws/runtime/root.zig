const smithy = @import("smithy/runtime");
pub const Set = smithy.Set;
pub const Response = smithy.Response;
pub const ResponseError = smithy.ResponseError;
pub const ErrorSource = smithy.ErrorSource;

const endpoint = @import("infra/endpoint.zig");
const partition = @import("infra/partitions.gen.zig");
const region = @import("infra/region.gen.zig");
pub const Region = region.Region;

const conf = @import("config.zig");
pub const Config = conf.Config;
pub const ConfigOptions = conf.ConfigOptions;
pub const ConfigResources = conf.ConfigResources;

const http = @import("http.zig");
pub const HttpClient = http.Client;
pub const SharedHttpClient = http.ClientProvider;

const sign = @import("auth/sign.zig");
const creds = @import("auth/creds.zig");
pub const Credentials = creds.Credentials;

pub const internal = struct {
    pub const ClientConfig = conf.ClientConfig;
    pub const Signer = sign.Signer;
    pub const HttpEvent = http.Event;
    pub const HttpService = http.Service;
    pub const HttpPayload = http.Payload;
    pub const HttpRequest = http.Request;
    pub const HttpResponse = http.Response;
    pub const Arn = endpoint.Arn;
    pub const Partition = endpoint.Partition;
    pub const isVirtualHostableS3Bucket = endpoint.isVirtualHostableS3Bucket;
    pub const resolvePartition = partition.resolve;
};

test {
    _ = @import("utils/url.zig");
    _ = @import("utils/time.zig");
    _ = @import("utils/hashing.zig");
    _ = @import("utils/SharedResource.zig");
    _ = @import("config/entries.zig");
    _ = @import("config/env.zig");
    _ = partition;
    _ = region;
    _ = creds;
    _ = sign;
    _ = endpoint;
    _ = http;
    _ = conf;
}
