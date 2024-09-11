const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const HttpClient = std.http.Client;
const testing = std.testing;
const test_alloc = testing.allocator;
const hashing = @import("utils/hashing.zig");
const TimeStr = @import("utils/TimeStr.zig");
const escapeUri = @import("utils/url.zig").escapeUri;
const SharedResource = @import("utils/SharedResource.zig");

const log = std.log.scoped(.aws_sdk);
const StringArrayMap = std.StringArrayHashMapUnmanaged([]const u8);

// Provides a shared HTTP client for multiple SDK clients.
pub const ClientProvider = struct {
    allocator: Allocator,
    client: Client = undefined,
    resource: SharedResource = .{},

    pub fn init(allocator: Allocator) ClientProvider {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ClientProvider) void {
        const count = self.resource.countSafe();
        if (count == 0) return;

        log.warn("Shared Http Client deinitialized while still used by {d} SDK clients.", .{count});
        self.client.forceDeinit();
        self.* = undefined;
    }

    pub fn retain(self: *ClientProvider) *Client {
        self.resource.retainCallback(createClient, self);
        return &self.client;
    }

    pub fn release(self: *ClientProvider, client: *Client) void {
        std.debug.assert(@intFromPtr(&self.client) == @intFromPtr(client));
        self.resource.releaseCallback(destroyClient, self);
    }

    fn createClient(self: *ClientProvider) void {
        self.client = Client.init(self.allocator);
        self.client.provider = self;
    }

    fn destroyClient(self: *ClientProvider) void {
        self.client.forceDeinit();
    }
};

pub const MAX_HEADERS_COUNT = 32;
pub const QueryBuffer = [2 * 1024]u8;
pub const HeadersRawBuffer = [4 * 1024]u8;
pub const HeadersPairsBuffer = [MAX_HEADERS_COUNT]std.http.Header;

pub const Client = struct {
    http: HttpClient,
    provider: ?*ClientProvider = null,

    pub fn init(allocator: Allocator) Client {
        return .{ .http = .{ .allocator = allocator } };
    }

    pub fn deinit(self: *Client) void {
        if (self.provider) |p| p.release(self) else self.forceDeinit();
    }

    fn forceDeinit(self: *Client) void {
        self.http.deinit();
        self.* = undefined;
    }

    pub fn sendSync(self: *Client, op: *Operation) !void {
        var extra_buff: HeadersPairsBuffer = undefined;
        var headers_managed: HttpClient.Request.Headers = .{};
        const header_extra = try op.request.splitHeaders(&extra_buff, &headers_managed);

        var query_str: QueryBuffer = undefined;
        const query = try op.request.stringifyQuery(&query_str);
        op.request.endpoint.query = .{ .percent_encoded = query };

        var out_headers_buff: HeadersRawBuffer = undefined;
        var out_body_buff = std.ArrayList(u8).init(op.allocator);
        errdefer out_body_buff.deinit();

        const result = try self.http.fetch(.{
            .method = op.request.method,
            .location = .{ .uri = op.request.endpoint },
            .headers = headers_managed,
            .extra_headers = header_extra,
            .payload = op.request.payload,
            .server_header_buffer = &out_headers_buff,
            .response_storage = .{ .dynamic = &out_body_buff },
        });

        const out_body = try out_body_buff.toOwnedSlice();
        errdefer op.allocator.free(out_body);

        const out_headers = if (mem.indexOf(u8, &out_headers_buff, "\r\n\r\n")) |len|
            try op.allocator.dupe(u8, out_headers_buff[0..len])
        else
            &.{};

        op.response = .{
            .status = result.status,
            .headers = out_headers,
            .body = out_body,
        };
    }
};

pub const Operation = struct {
    allocator: Allocator,
    time: TimeStr,
    request: Request,
    response: ?Response = null,

    pub fn init(allocator: Allocator, method: std.http.Method, endpoint: std.Uri, app_id: ?[]const u8, trace_id: ?[]const u8) !*Operation {
        const self = try allocator.create(Operation);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .time = TimeStr.now(),
            .request = undefined,
        };

        var request: Request = .{
            .endpoint = endpoint,
            .method = method,
        };
        errdefer request.deinit(allocator);

        try request.headers.put(allocator, "x-amz-date", self.time.timestamp());
        try request.headers.put(allocator, "host", try endpoint.host.?.toRawMaybeAlloc(undefined));
        if (trace_id) |tid| try request.headers.put(allocator, "x-amzn-trace-id", tid);

        self.request = request;
        return self;
    }

    pub fn deinit(self: *Operation) void {
        self.request.deinit(self.allocator);
        if (self.response) |t| t.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

pub const Response = struct {
    status: std.http.Status,
    headers: []const u8,
    body: []const u8,

    pub fn deinit(self: Response, allocator: Allocator) void {
        allocator.free(self.headers);
        allocator.free(self.body);
    }
};

pub const Request = struct {
    endpoint: std.Uri,
    method: std.http.Method,
    query: StringArrayMap = .{},
    headers: StringArrayMap = .{},
    payload: ?[]const u8 = null,

    const MANAGED_HEADERS = std.StaticStringMap([]const u8).initComptime(.{
        .{ "host", "host" },
        .{ "user-agent", "user_agent" },
        .{ "content-type", "content_type" },
        .{ "authorization", "authorization" },
        .{ "accept-encoding", "accept_encoding" },
        .{ "connection", "connection" },
    });

    pub fn deinit(self: *Request, allocator: Allocator) void {
        self.query.deinit(allocator);
        self.headers.deinit(allocator);
    }

    pub fn stringifyQuery(self: Request, out_buffer: *QueryBuffer) ![]const u8 {
        var scratch_buff: HeadersRawBuffer = undefined;
        var scratch_fixed = std.heap.FixedBufferAllocator.init(&scratch_buff);
        const scratch_alloc = scratch_fixed.allocator();

        var count: usize = 0;
        var kvs: HeadersPairsBuffer = undefined;
        var it = self.query.iterator();
        while (it.next()) |kv| : (count += 1) {
            const name_fmt = try escapeUri(scratch_alloc, kv.key_ptr.*);
            const value_fmt = try escapeUri(scratch_alloc, kv.value_ptr.*);
            kvs[count] = .{ .name = name_fmt, .value = value_fmt };
        }
        std.mem.sort(std.http.Header, kvs[0..count], {}, sortHeaderName);

        var out_stream = std.io.fixedBufferStream(out_buffer);
        const out_writer = out_stream.writer();
        for (0..count) |i| {
            const kv = kvs[i];
            if (i > 0) try out_writer.writeByte('&');
            try out_writer.print("{s}={s}", .{ kv.name, kv.value });
        }
        return out_stream.getWritten();
    }

    pub fn stringifyHeaders(self: Request, out_buffer: *HeadersRawBuffer) ![]const u8 {
        var scratch_buff: HeadersRawBuffer = undefined;
        var scratch_fixed = std.heap.FixedBufferAllocator.init(&scratch_buff);
        const scratch_alloc = scratch_fixed.allocator();

        var count: usize = 0;
        var kvs: HeadersPairsBuffer = undefined;
        var it = self.headers.iterator();
        while (it.next()) |kv| : (count += 1) {
            const name_fmt = try std.ascii.allocLowerString(scratch_alloc, kv.key_ptr.*);
            const value_fmt = mem.trim(u8, kv.value_ptr.*, &std.ascii.whitespace);
            kvs[count] = .{ .name = name_fmt, .value = value_fmt };
        }
        std.mem.sort(std.http.Header, kvs[0..count], {}, sortHeaderName);

        var out_stream = std.io.fixedBufferStream(out_buffer);
        const out_writer = out_stream.writer();
        for (kvs[0..count]) |kv| {
            try out_writer.print("{s}:{s}\n", .{ kv.name, kv.value });
        }
        return out_stream.getWritten();
    }

    pub fn stringifyHeadNames(self: Request, out_buffer: *QueryBuffer) ![]const u8 {
        var scratch_buff: QueryBuffer = undefined;
        var scratch_fixed = std.heap.FixedBufferAllocator.init(&scratch_buff);
        const scratch_alloc = scratch_fixed.allocator();

        const count: usize = self.headers.count();
        var names: [MAX_HEADERS_COUNT][]const u8 = undefined;
        for (self.headers.keys(), 0..) |name, i| {
            names[i] = try std.ascii.allocLowerString(scratch_alloc, name);
        }
        std.mem.sort([]const u8, names[0..count], {}, sortString);

        var out_stream = std.io.fixedBufferStream(out_buffer);
        const out_writer = out_stream.writer();
        for (names[0..count], 0..) |name, i| {
            if (i > 0) try out_writer.writeByte(';');
            try out_writer.writeAll(name);
        }
        return out_stream.getWritten();
    }

    pub fn hashPayload(self: Request, out_buffer: *hashing.HashStr) void {
        hashing.hashString(out_buffer, self.payload);
    }

    pub fn splitHeaders(self: Request, buffer: *HeadersPairsBuffer, managed: *HttpClient.Request.Headers) ![]const std.http.Header {
        var len: usize = 0;
        var it = self.headers.iterator();
        while (it.next()) |kv| {
            const name = kv.key_ptr.*;
            const value = kv.value_ptr.*;
            if (MANAGED_HEADERS.has(name)) {
                mngd: inline for (comptime MANAGED_HEADERS.keys()) |key| {
                    const field = comptime MANAGED_HEADERS.get(key).?;
                    if (mem.eql(u8, key, name)) {
                        @field(managed, field) = .{ .override = value };
                        break :mngd;
                    }
                }
            } else {
                buffer[len] = .{ .name = name, .value = value };
                len += 1;
            }
        }

        return buffer[0..len];
    }
};

fn sortString(_: void, l: []const u8, r: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(l, r);
}

fn sortHeaderName(_: void, lhs: std.http.Header, rhs: std.http.Header) bool {
    return std.ascii.lessThanIgnoreCase(lhs.name, rhs.name);
}

test "Request.stringifyQuery" {
    var request = try testRequest();
    defer request.deinit(test_alloc);

    var buffer: QueryBuffer = undefined;
    const query = try request.stringifyQuery(&buffer);
    try testing.expectEqualStrings("baz=%24qux&foo=%25bar", query);
}

test "Request.stringifyHeaders" {
    var request = try testRequest();
    defer request.deinit(test_alloc);

    var buffer: HeadersRawBuffer = undefined;
    const headers = try request.stringifyHeaders(&buffer);
    try testing.expectEqualStrings("host:s3.amazonaws.com\nx-amz-date:20130708T220855Z\n", headers);
}

test "Request.stringifyHeadNames" {
    var request = try testRequest();
    defer request.deinit(test_alloc);

    var buffer: QueryBuffer = undefined;
    const names = try request.stringifyHeadNames(&buffer);
    try testing.expectEqualStrings("host;x-amz-date", names);
}

test "Request.hashPayload" {
    var request = try testRequest();
    defer request.deinit(test_alloc);

    var hash: hashing.HashStr = undefined;
    request.hashPayload(&hash);
    try testing.expectEqualStrings("269dce1a5bb90188b2d9cf542a7c30e410c7d8251e34a97bfea56062df51ae23", &hash);
}

fn testRequest() !Request {
    var request = Request{
        .method = .GET,
        .endpoint = .{ .scheme = "http" },
        .payload = "foo-bar-baz",
    };

    try request.headers.put(test_alloc, "Host", "s3.amazonaws.com");
    try request.headers.put(test_alloc, "X-amz-date", "20130708T220855Z");

    try request.query.put(test_alloc, "foo", "%bar");
    try request.query.put(test_alloc, "baz", "$qux");

    return request;
}
