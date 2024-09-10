const std = @import("std");
const sig = @import("sigv4.zig");
const http = @import("../http.zig");
const Credentials = @import("creds.zig").Credentials;
const Region = @import("../infra/region.gen.zig").Region;
const hashing = @import("../utils/hashing.zig");

pub fn signV4(buffer: *sig.SignBuffer, op: *http.Operation, service: []const u8, region: Region, creds: Credentials) !void {
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
        .service = service,
        .region = region.toCode(),
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
