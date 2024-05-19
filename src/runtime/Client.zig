//! Make HTTP requests to AWS services.
const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const Signer = @import("Signer.zig");
const Endpoint = @import("Endpoint.zig");
const transmit = @import("transmit.zig");

// TODO: Use `std.http.Client` once AWS TLS 1.3 support is complete or Zig adds TLS 1.2 support
// https://aws.amazon.com/blogs/security/faster-aws-cloud-connections-with-tls-1-3
// https://github.com/ziglang/zig/pull/19308
// https://github.com/ziglang/zig/issues/17213
const HttpClient = @import("https12");

var gpa: std.heap.GeneralPurposeAllocator(.{}) = undefined;
var shared: Self = undefined;
var shared_count: usize = 0;

pub fn retain() *Self {
    if (shared_count == 0) {
        const alloc = if (@import("builtin").is_test) test_alloc else blk: {
            gpa = .{};
            break :blk gpa.allocator();
        };
        shared = Self.init(alloc);
    }

    shared_count += 1;
    return &shared;
}

pub fn release() void {
    std.debug.assert(shared_count > 0);
    if (shared_count > 1) {
        shared_count -= 1;
    } else {
        shared_count = 0;
        shared.deinit();
        shared = undefined;
        _ = gpa.deinit();
        gpa = undefined;
    }
}

const Self = @This();
const AuthBuffer = [512]u8;
const HeadersBuffer = [2 * 1024]u8;

http: HttpClient,

fn init(allocator: Allocator) Self {
    return .{ .http = .{ .allocator = allocator } };
}

fn deinit(self: *Self) void {
    self.http.deinit();
    self.* = undefined;
}

/// The caller owns the returned response memory.
///
/// Optionally provide an _arena allocator_ instead of calling `deinit` on the response.
pub fn send(
    self: *Self,
    allocator: Allocator,
    endpoint: Endpoint,
    request: *transmit.Request,
    signer: Signer,
) !transmit.Response {
    const time = transmit.TimeStr.initNow();
    const sign_event = Signer.Event{
        .service = endpoint.service,
        .region = endpoint.region.code(),
        .date = &time.date,
        .timestamp = &time.timestamp,
    };

    try request.addHeaders(&.{
        .{ .key = "host", .value = endpoint.host },
        .{ .key = "x-amz-date", .value = &time.timestamp },
    });
    if (request.payload) |p| try request.addHeader("content-type", p.mime());

    const headers_str = try request.headersString(allocator);
    defer allocator.free(headers_str);
    const headers_names_str = try request.headersNamesString(allocator);
    defer allocator.free(headers_names_str);
    const query_str = try request.queryString(allocator);
    defer allocator.free(query_str);
    const payload_hash = request.payloadHash();
    const sign_content = Signer.Content{
        .method = request.method,
        .path = request.path,
        .query = query_str,
        .headers = headers_str,
        .headers_names = headers_names_str,
        .payload_hash = &payload_hash,
    };

    var auth_buffer: AuthBuffer = undefined;
    const auth = try signer.handle(&auth_buffer, sign_event, sign_content);

    var body_buffer = std.ArrayList(u8).init(allocator);
    errdefer body_buffer.deinit();

    // Filter out headers that are managed by the HTTP client
    const managed_headers = std.ComptimeStringMap(void, .{
        .{"host"},       .{"authorization"},   .{"user-agent"},
        .{"connection"}, .{"accept-encoding"}, .{"content-type"},
    });
    var extra_len: usize = 0;
    var extra_headers: [transmit.MAX_HEADERS]std.http.Header = undefined;
    var it = request.headers.iterator();
    while (it.next()) |kv| {
        if (managed_headers.has(kv.key_ptr.*)) continue;
        extra_headers[extra_len] = .{ .name = kv.key_ptr.*, .value = kv.value_ptr.* };
        extra_len += 1;
    }

    var headers_buffer: HeadersBuffer = undefined;
    const result = try self.http.fetch(.{
        .location = .{ .uri = endpoint.uri(request.path) },
        .method = .GET,
        .keep_alive = endpoint.keep_alive,
        .headers = .{
            .authorization = .{ .override = auth },
            .host = .{ .override = endpoint.host },
            .content_type = if (request.payload) |p| .{ .override = p.mime() } else .default,
        },
        .extra_headers = extra_headers[0..extra_len],
        .payload = if (request.payload) |p| p.content else null,
        .server_header_buffer = &headers_buffer,
        .response_storage = .{ .dynamic = &body_buffer },
    });

    const headers_dupe = if (std.mem.indexOf(u8, &headers_buffer, "\r\n\r\n")) |i|
        try allocator.dupe(u8, headers_buffer[0..i])
    else
        &.{};
    errdefer allocator.free(headers_dupe);
    return .{
        .allocator = allocator,
        .status = result.status,
        .headers = headers_dupe,
        .body = try body_buffer.toOwnedSlice(),
    };
}

