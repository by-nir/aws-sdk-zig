const result = @import("result.zig");
pub const Result = result.Result;
pub const ErrorSource = result.ErrorSource;

const containers = @import("containers.zig");
pub const Set = containers.SetUnmanaged;

const url = @import("url.zig");
const http = @import("http.zig");
const values = @import("values.zig");
const endpoint = @import("endpoint.zig");
pub const internal = struct {
    pub const RulesUrl = url.RulesUrl;
    pub const uriEncode = url.uriEncode;
    pub const isValidHostLabel = url.isValidHostLabel;
    pub const HttpHeader = http.HttpHeader;
    pub const Document = values.Document;
    pub const substring = values.substring;
    pub const Endpoint = endpoint.Endpoint;
    pub const AuthScheme = endpoint.AuthScheme;
};

test {
    _ = url;
    _ = http;
    _ = result;
    _ = values;
    _ = endpoint;
    _ = containers;
}
