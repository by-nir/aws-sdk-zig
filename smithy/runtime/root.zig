const result = @import("primitives/result.zig");
pub const Result = result.Result;
pub const ResultError = result.ResultError;
pub const ErrorSource = result.ErrorSource;

const collection = @import("primitives/collection.zig");
pub const Set = collection.Set;
pub const Map = collection.Map;

const rules = @import("operation/rules.zig");
pub const RulesUrl = rules.RulesUrl;
pub const uriEncode = rules.uriEncode;
pub const isValidHostLabel = rules.isValidHostLabel;
pub const substring = rules.substring;

const request = @import("operation/request.zig");
pub const AuthId = request.AuthId;
pub const Endpoint = request.Endpoint;
pub const AuthScheme = request.AuthScheme;
pub const HttpHeader = request.HttpHeader;

const document = @import("operation/document.zig");
pub const Document = document.Document;

const serial = @import("operation/serial.zig");
pub const SerialType = serial.SerialType;

test {
    _ = result;
    _ = collection;
    _ = document;
    _ = request;
    _ = rules;
    _ = serial;
}
