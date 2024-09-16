//! https://github.com/awslabs/aws-c-auth
const std = @import("std");
const mem = std.mem;
const smithy = @import("smithy/runtime");
const sig = @import("sigv4.zig");
const http = @import("../http.zig");
const Credentials = @import("creds.zig").Credentials;
const Region = @import("../infra/region.gen.zig").Region;
const hashing = @import("../utils/hashing.zig");

const log = std.log.scoped(.aws_sdk);

pub const SigV4Scheme = struct {
    /// The _service_ value to use when creating a signing string for this endpoint.
    signing_name: []const u8,
    /// The _region_ value to use when creating a signing string for this endpoint.
    signing_region: []const u8,
    /// When `true` clients must not double-escape the path during signing.
    disable_double_encoding: bool = false,
    /// When `true` clients must not perform any path normalization during signing.
    disable_normalize_path: bool = false,

    pub fn evaluate(service: []const u8, region: []const u8, endpoint: ?smithy.AuthScheme) SigV4Scheme {
        var scheme = SigV4Scheme{
            .signing_name = service,
            .signing_region = region,
        };

        const override = endpoint orelse return scheme;

        std.debug.assert(override.id == smithy.AuthId.of("sigv4"));
        for (override.properties) |prop| {
            if (mem.eql(u8, "signingName", prop.key)) {
                scheme.signing_name = prop.document.getString();
            } else if (mem.eql(u8, "signingRegion", prop.key)) {
                scheme.signing_region = prop.document.getString();
            } else if (mem.eql(u8, "disableDoubleEncoding", prop.key)) {
                scheme.disable_double_encoding = prop.document.boolean;
            } else if (mem.eql(u8, "disableNormalizePath", prop.key)) {
                scheme.disable_normalize_path = prop.document.boolean;
            } else {
                log.warn("Unknown property in the resolved endpoint’s 'sigv4' auth scheme: {s}.", .{prop.key});
            }
        }
        return scheme;
    }
};

// TODO: SigV4Scheme.disable_double_encoding, SigV4Scheme.disable_normalize_path
pub fn signV4(buffer: *sig.SignBuffer, op: *http.Operation, scheme: SigV4Scheme, creds: Credentials) !void {
    const req = &op.request;
    const path = if (req.endpoint.path.isEmpty()) "/" else req.endpoint.path.raw;

    var values_buff: http.HeadersRawBuffer = undefined;
    const headers = try req.stringifyHeaders(&values_buff);

    var names_buff: http.QueryBuffer = undefined;
    const names = try req.stringifyHeadNames(&names_buff);

    var query_buff: http.QueryBuffer = undefined;
    const query = try req.stringifyQuery(&query_buff);

    var payload_hash: hashing.HashStr = undefined;
    req.hashPayload(&payload_hash);

    const target = sig.Target{
        .service = scheme.signing_name,
        .region = scheme.signing_region,
    };

    const content = sig.Content{
        .method = req.method,
        .path = path,
        .query = query,
        .headers = headers,
        .headers_names = names,
        .payload_hash = &payload_hash,
    };

    const signature = try sig.signV4(buffer, creds, op.time, target, content);
    try req.headers.put(op.allocator, "authorization", signature);
}

pub const SigV4AScheme = struct {
    /// The _service_ value to use when creating a signing string for this endpoint.
    signing_name: []const u8,
    /// The set of signing regions to use when creating a signing string for this endpoint.
    signing_region_set: []const []const u8,
    /// When `true` clients must not double-escape the path during signing.
    disable_double_encoding: bool = false,
    /// When `true` clients must not perform any path normalization during signing.
    disable_normalize_path: bool = false,

    pub fn evaluate(endpoint: smithy.AuthScheme, service: []const u8, region: []const u8) SigV4AScheme {
        _ = region; // autofix
        std.debug.assert(endpoint.id == smithy.AuthId.of("sigv4a"));
        var scheme = SigV4AScheme{
            .signing_name = service,
            .signing_region_set = &.{},
        };

        var visited_regions = false;
        for (endpoint.properties) |prop| {
            if (mem.eql(u8, "signingName", prop.key)) {
                scheme.signing_name = prop.document.getString();
            } else if (mem.eql(u8, "signingRegionSet", prop.key)) {
                visited_regions = true;
                unreachable; // TODO: scheme.signing_region_set = ;
            } else if (mem.eql(u8, "disableDoubleEncoding", prop.key)) {
                scheme.disable_double_encoding = prop.document.boolean;
            } else if (mem.eql(u8, "disableNormalizePath", prop.key)) {
                scheme.disable_normalize_path = prop.document.boolean;
            } else {
                log.warn("Unknown property in the resolved endpoint’s 'sigv4a' auth scheme: {s}.", .{prop.key});
            }
        }

        std.debug.assert(visited_regions);
        return scheme;
    }
};
