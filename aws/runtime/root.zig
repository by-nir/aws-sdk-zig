const smithy = @import("smithy/runtime");
pub const Set = smithy.Set;
pub const Result = smithy.Result;
pub const ResultError = smithy.ResultError;
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

const auth_sign = @import("auth/sigv4.zig");
const auth_schemes = @import("auth/schemes.zig");
const auth_creds = @import("auth/creds.zig");
pub const Credentials = auth_creds.Credentials;

pub const _private_ = struct {
    pub const ClientConfig = conf.ClientConfig;
    pub const ClientOperation = http.Operation;
    pub const ClientRequest = http.Request;
    pub const ClientResponse = http.Response;
    pub const Arn = endpoint.Arn;
    pub const Partition = endpoint.Partition;
    pub const isVirtualHostableS3Bucket = endpoint.isVirtualHostableS3Bucket;
    pub const resolvePartition = partition.resolve;
    pub const SignBuffer = auth_sign.SignBuffer;
    pub const auth = auth_schemes;
    pub const protocol = struct {
        pub const json = protocol_json;
    };
};

const protocol_json = @import("protocols/json.zig");

test {
    _ = @import("utils/url.zig");
    _ = @import("utils/hashing.zig");
    _ = @import("utils/TimeStr.zig");
    _ = @import("utils/SharedResource.zig");
    _ = @import("config/entries.zig");
    _ = @import("config/env.zig");
    _ = region;
    _ = endpoint;
    _ = partition;
    _ = _private_.ClientOperation;
    _ = auth_creds;
    _ = auth_schemes;
    _ = @import("auth/sigv4.zig");
    _ = protocol_json;
    _ = http;
    _ = conf;
}
