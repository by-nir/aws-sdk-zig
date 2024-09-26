const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const HttpClient = std.http.Client;
const testing = std.testing;
const test_alloc = testing.allocator;
const TimeStr = @import("utils/TimeStr.zig");
const escapeUri = @import("utils/url.zig").escapeUri;
const SharedResource = @import("utils/SharedResource.zig");

const log = std.log.scoped(.aws_sdk);

/// Provides a shared HTTP client for multiple SDK clients.
pub const SharedClient = struct {
    allocator: Allocator,
    client: Client = undefined,
    tracker: SharedResource = .{},

    pub fn init(allocator: Allocator) SharedClient {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SharedClient) void {
        const count = self.tracker.countSafe();
        if (count == 0) return;

        log.warn("Deinit shared Http Client while still used by {d} SDK clients.", .{count});
        self.client.forceDeinit();
        self.* = undefined;
    }

    pub fn retain(self: *SharedClient) *Client {
        self.tracker.retainCallback(createClient, self);
        return &self.client;
    }

    pub fn release(self: *SharedClient, client: *Client) void {
        std.debug.assert(@intFromPtr(&self.client) == @intFromPtr(client));
        self.tracker.releaseCallback(destroyClient, self);
    }

    fn createClient(self: *SharedClient) void {
        self.client = Client.init(self.allocator);
        self.client.shared = self;
    }

    fn destroyClient(self: *SharedClient) void {
        self.client.forceDeinit();
    }
};

pub const MAX_HEADERS_COUNT = 32;
pub const QueryBuffer = [2 * 1024]u8;
pub const HeadersRawBuffer = [4 * 1024]u8;
pub const HeadersPairsBuffer = [MAX_HEADERS_COUNT]std.http.Header;
pub const PropertiesMap = std.StringArrayHashMapUnmanaged([]const u8);

pub const Client = struct {
    http: HttpClient,
    shared: ?*SharedClient = null,

    pub fn init(allocator: Allocator) Client {
        return .{ .http = .{ .allocator = allocator } };
    }

    pub fn deinit(self: *Client) void {
        if (self.shared) |p| p.release(self) else self.forceDeinit();
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
        const out_headers = if (mem.indexOf(u8, &out_headers_buff, "\r\n\r\n")) |len|
            try op.allocator.dupe(u8, out_headers_buff[0 .. len + 4])
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

    pub fn new(
        allocator: Allocator,
        method: std.http.Method,
        endpoint: std.Uri,
        app_id: ?[]const u8,
        trace_id: ?[]const u8,
    ) !*Operation {
        const self = try allocator.create(Operation);
        self.* = .{
            .allocator = allocator,
            .time = TimeStr.now(),
            .request = undefined,
        };

        var request: Request = .{
            .endpoint = endpoint,
            .method = method,
        };

        try request.putHeader(allocator, "x-amz-date", self.time.timestamp());
        try request.putHeader(allocator, "host", try endpoint.host.?.toRawMaybeAlloc(undefined));
        if (trace_id) |tid| try request.putHeader(allocator, "x-amzn-trace-id", tid);

        self.request = request;
        return self;
    }
};

pub const Response = struct {
    status: std.http.Status,
    headers: []const u8,
    body: []const u8,

    pub fn headersIterator(self: Response) std.http.HeaderIterator {
        return std.http.HeaderIterator.init(self.headers);
    }
};

pub const Request = struct {
    endpoint: std.Uri,
    method: std.http.Method,
    query: PropertiesMap = .{},
    headers: PropertiesMap = .{},
    payload: ?[]const u8 = null,

    const MANAGED_HEADERS = std.StaticStringMap([]const u8).initComptime(.{
        .{ "host", "host" },
        .{ "user-agent", "user_agent" },
        .{ "content-type", "content_type" },
        .{ "authorization", "authorization" },
        .{ "accept-encoding", "accept_encoding" },
        .{ "connection", "connection" },
    });

    pub fn putQuery(self: *Request, allocator: Allocator, key: []const u8, value: []const u8) !void {
        try self.query.put(allocator, key, value);
    }

    pub fn putHeader(self: *Request, allocator: Allocator, key: []const u8, value: []const u8) !void {
        try self.headers.put(allocator, key, value);
    }

    pub fn stringifyQuery(self: *Request, out_buffer: *QueryBuffer) ![]const u8 {
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
        mem.sort(std.http.Header, kvs[0..count], {}, sortHeaderName);

        var out_stream = std.io.fixedBufferStream(out_buffer);
        const out_writer = out_stream.writer();
        for (0..count) |i| {
            const kv = kvs[i];
            if (i > 0) try out_writer.writeByte('&');
            try out_writer.print("{s}={s}", .{ kv.name, kv.value });
        }
        return out_stream.getWritten();
    }

    pub fn stringifyHeaders(self: *Request, out_buffer: *HeadersRawBuffer) ![]const u8 {
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
        mem.sort(std.http.Header, kvs[0..count], {}, sortHeaderName);

        var out_stream = std.io.fixedBufferStream(out_buffer);
        const out_writer = out_stream.writer();
        for (kvs[0..count]) |kv| {
            try out_writer.print("{s}:{s}\n", .{ kv.name, kv.value });
        }
        return out_stream.getWritten();
    }

    pub fn stringifyHeadNames(self: *Request, out_buffer: *QueryBuffer) ![]const u8 {
        var scratch_buff: QueryBuffer = undefined;
        var scratch_fixed = std.heap.FixedBufferAllocator.init(&scratch_buff);
        const scratch_alloc = scratch_fixed.allocator();

        const count: usize = self.headers.count();
        var names: [MAX_HEADERS_COUNT][]const u8 = undefined;
        for (self.headers.keys(), 0..) |name, i| {
            names[i] = try std.ascii.allocLowerString(scratch_alloc, name);
        }
        mem.sort([]const u8, names[0..count], {}, sortString);

        var out_stream = std.io.fixedBufferStream(out_buffer);
        const out_writer = out_stream.writer();
        for (names[0..count], 0..) |name, i| {
            if (i > 0) try out_writer.writeByte(';');
            try out_writer.writeAll(name);
        }
        return out_stream.getWritten();
    }

    fn splitHeaders(
        self: Request,
        buffer: *HeadersPairsBuffer,
        managed: *HttpClient.Request.Headers,
    ) ![]const std.http.Header {
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

test "Request.stringifyQuery" {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    defer arena.deinit();

    var request = try testRequest(arena.allocator());

    var buffer: QueryBuffer = undefined;
    const query = try request.stringifyQuery(&buffer);
    try testing.expectEqualStrings("baz=%24qux&foo=%25bar", query);
}

test "Request.stringifyHeaders" {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    defer arena.deinit();

    var request = try testRequest(arena.allocator());

    var buffer: HeadersRawBuffer = undefined;
    const headers = try request.stringifyHeaders(&buffer);
    try testing.expectEqualStrings("host:s3.amazonaws.com\nx-amz-date:20130708T220855Z\n", headers);
}

test "Request.stringifyHeadNames" {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    defer arena.deinit();

    var request = try testRequest(arena.allocator());

    var buffer: QueryBuffer = undefined;
    const names = try request.stringifyHeadNames(&buffer);
    try testing.expectEqualStrings("host;x-amz-date", names);
}

fn sortString(_: void, l: []const u8, r: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(l, r);
}

fn sortHeaderName(_: void, lhs: std.http.Header, rhs: std.http.Header) bool {
    return std.ascii.lessThanIgnoreCase(lhs.name, rhs.name);
}

fn testRequest(allocator: Allocator) !Request {
    var request = Request{
        .method = .GET,
        .endpoint = .{ .scheme = "http" },
        .payload = "foo-bar-baz",
    };

    try request.putHeader(allocator, "Host", "s3.amazonaws.com");
    try request.putHeader(allocator, "X-amZ-dAte", "20130708T220855Z");

    try request.putQuery(allocator, "foo", "%bar");
    try request.putQuery(allocator, "baz", "$qux");

    return request;
}
