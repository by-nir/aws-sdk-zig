const smithy = @import("smithy/runtime");
pub const Set = smithy.Set;
pub const Map = smithy.Map;
pub const Result = smithy.Result;
pub const Timestamp = smithy.Timestamp;
pub const ResultError = smithy.ResultError;
pub const ErrorSource = smithy.ErrorSource;

const endpoint = @import("infra/endpoint.zig");
const partition = @import("infra/partitions.gen.zig");
const region = @import("infra/region.gen.zig");
pub const Region = region.Region;

const conf = @import("config.zig");
pub const Config = conf.Config;
pub const SharedConfig = conf.SharedConfig;
pub const ConfigOptions = conf.ConfigOptions;

const http = @import("http.zig");
pub const HttpClient = http.SharedClient;

const identity = @import("auth/identity.zig");
pub const IdentityManager = identity.SharedManager;
pub const StandardIdentity = identity.StandardCredsProvider;
pub const StaticIdentity = identity.StaticCredsProvider;
pub const EnvIdentity = identity.EnvironmentCredsProvider;
pub const SharedFilesIdentity = identity.SharedFilesProvider;

const auth_sign = @import("auth/sigv4.zig");
const auth_schemes = @import("auth/schemes.zig");

const protocol_http = @import("protocols/http.zig");
const protocol_json = @import("protocols/json.zig");
const protocol_xml = @import("protocols/xml.zig");
const protocol_query = @import("protocols/query.zig");

pub const _private_ = struct {
    pub const ClientConfig = conf.ClientConfig;
    pub const ClientRequest = http.Request;
    pub const ClientResponse = http.Response;
    pub const ClientOperation = http.Operation;
    pub const HttpClient = http.Client;
    pub const IdentityManager = identity.Manager;
    pub const Arn = endpoint.Arn;
    pub const Partition = endpoint.Partition;
    pub const isVirtualHostableS3Bucket = endpoint.isVirtualHostableS3Bucket;
    pub const resolvePartition = partition.resolve;
    pub const SignBuffer = auth_sign.SignBuffer;
    pub const auth = auth_schemes;
    pub const protocol = struct {
        pub const http = protocol_http;
        pub const json = protocol_json;
        pub const xml = protocol_xml;
        pub const query = protocol_query;
    };
};

test {
    _ = @import("utils/url.zig");
    _ = @import("utils/hashing.zig");
    _ = @import("utils/TimeStr.zig");
    _ = @import("utils/SharedResource.zig");
    _ = @import("config/entries.zig");
    _ = @import("config/env.zig");
    _ = @import("config/profile.zig");
    _ = region;
    _ = endpoint;
    _ = partition;
    _ = _private_.ClientOperation;
    _ = identity;
    _ = auth_schemes;
    _ = @import("auth/sigv4.zig");
    _ = protocol_http;
    _ = protocol_json;
    _ = protocol_xml;
    _ = protocol_query;
    _ = http;
    _ = conf;
}
