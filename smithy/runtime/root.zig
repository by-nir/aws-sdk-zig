const result = @import("primitives/result.zig");
pub const Result = result.Result;
pub const ResultError = result.ResultError;
pub const ErrorSource = result.ErrorSource;

const collection = @import("primitives/collection.zig");
pub const Set = collection.Set;
pub const Map = collection.Map;

pub const Timestamp = @import("primitives/Timestamp.zig");

pub const rules = @import("operation/rules.zig");
pub const RulesUrl = rules.RulesUrl;

const request = @import("operation/request.zig");
pub const AuthId = request.AuthId;
pub const Endpoint = request.Endpoint;
pub const AuthScheme = request.AuthScheme;
pub const HttpHeader = request.HttpHeader;

const document = @import("operation/document.zig");
pub const Document = document.Document;

pub const serial = @import("operation/serial.zig");
pub const SerialType = serial.SerialType;

pub const validate = @import("operation/validate.zig");

test {
    _ = result;
    _ = collection;
    _ = Timestamp;
    _ = document;
    _ = request;
    _ = rules;
    _ = serial;
    _ = validate;
}
