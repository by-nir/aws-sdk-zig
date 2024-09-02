const std = @import("std");
const assert = std.debug.assert;
const HttpClient = std.http.Client;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const sign = @import("sign.zig");
const utils = @import("utils.zig");
const Region = @import("config/region.gen.zig").Region;

const MAX_HEADERS = 1024;
const QueryBuffer = [1024]u8;
const HeadersRawBuffer = [4 * 1024]u8;
const HeadersKVBuffer = [MAX_HEADERS]KVMap.Pair;

pub const Client = struct {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = undefined;
    var shared: Client = undefined;
    var shared_count: usize = 0;

    pub fn retain() *Client {
        if (shared_count == 0) {
            const alloc = if (@import("builtin").is_test) test_alloc else blk: {
                gpa = .{};
                break :blk gpa.allocator();
            };
            shared = Client.init(alloc);
        }

        shared_count += 1;
        return &shared;
    }

    pub fn release() void {
        assert(shared_count > 0);
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

    const HeadersBuffer = [2 * 1024]u8;

    http: HttpClient,

    fn init(allocator: Allocator) Client {
        return .{
            .http = .{ .allocator = allocator },
        };
    }

    fn deinit(self: *Client) void {
        self.http.deinit();
        self.* = undefined;
    }

    /// The caller owns the returned response memory.
    ///
    /// Optionally provide an _arena allocator_ instead of calling `deinit` on the response.
    pub fn send(
        self: *Client,
        allocator: Allocator,
        signer: sign.Signer,
        endpoint: std.Uri,
        action: Action,
        request: *Request,
    ) !Response {
        try request.addHeaders(&.{
            .{ .key = "host", .value = try endpoint.host.?.toRawMaybeAlloc(allocator) },
            .{ .key = "x-amz-date", .value = &action.timestamp },
        });
        if (action.trace_id) |tid| try request.addHeader("x-amzn-trace-id", tid);
        if (request.payload) |pld| try request.addHeader("content-type", pld.mime());

        var auth_buffer: [512]u8 = undefined;
        const auth = try signRequest(allocator, &auth_buffer, signer, request, action);
        return self.sendRequest(allocator, endpoint, request, auth);
    }

    fn signRequest(
        allocator: Allocator,
        buffer: []u8,
        signer: sign.Signer,
        request: *Request,
        action: Action,
    ) ![]const u8 {
        const headers_str = try request.headersString(allocator);
        defer allocator.free(headers_str);

        const headers_names_str = try request.headersNamesString(allocator);
        defer allocator.free(headers_names_str);

        const query_str = try request.queryString(allocator);
        defer allocator.free(query_str);

        const payload_hash = request.payloadHash();
        const sign_content = sign.Content{
            .method = request.method,
            .path = request.path,
            .query = query_str,
            .headers = headers_str,
            .headers_names = headers_names_str,
            .payload_hash = &payload_hash,
        };

        return signer.sign(buffer, .{
            .service = action.service,
            .region = action.region.toCode(),
            .date = &action.date,
            .timestamp = &action.timestamp,
        }, sign_content);
    }

    fn sendRequest(
        self: *Client,
        allocator: Allocator,
        endpoint: std.Uri,
        request: *Request,
        auth: []const u8,
    ) !Response {
        var body_buffer = std.ArrayList(u8).init(allocator);
        errdefer body_buffer.deinit();

        // Filter out headers that are managed by the HTTP client
        const managed_headers = std.StaticStringMap(void).initComptime(.{
            .{"host"},       .{"authorization"},   .{"user-agent"},
            .{"connection"}, .{"accept-encoding"}, .{"content-type"},
        });
        var extra_len: usize = 0;
        var extra_headers: [MAX_HEADERS]std.http.Header = undefined;
        var it = request.headers.iterator();
        while (it.next()) |kv| {
            if (managed_headers.has(kv.key_ptr.*)) continue;
            extra_headers[extra_len] = .{ .name = kv.key_ptr.*, .value = kv.value_ptr.* };
            extra_len += 1;
        }

        var location = endpoint;
        location.path = .{ .raw = request.path };
        location.query = .{ .percent_encoded = try request.queryString(allocator) };

        var headers_buffer: HeadersBuffer = undefined;
        const result = try self.http.fetch(.{
            .location = .{ .uri = location },
            .method = .GET,
            .headers = .{
                .authorization = .{ .override = auth },
                .host = .{ .override = try endpoint.host.?.toRawMaybeAlloc(allocator) },
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
};

pub const Action = struct {
    region: Region,
    service: []const u8,
    app_id: ?[]const u8 = null,
    trace_id: ?[]const u8 = null,
    date: [8]u8 = std.mem.zeroes([8]u8),
    timestamp: [16]u8 = std.mem.zeroes([16]u8),

    pub fn base(service: []const u8, region: Region, app_id: ?[]const u8) Action {
        return .{
            .service = service,
            .region = region,
            .app_id = app_id,
        };
    }

    pub fn copyNow(self: Action, trace_id: ?[]const u8) Action {
        const time = utils.TimeStr.initNow();
        var dupe = self;
        dupe.trace_id = trace_id;
        dupe.date = time.date;
        dupe.timestamp = time.timestamp;
        return dupe;
    }
};

/// HTTP request configuration and content.
pub const Request = struct {
    allocator: Allocator,
    method: std.http.Method,
    query: KVMap,
    path: []const u8,
    headers: KVMap,
    payload: ?Payload = null,

    pub const Schema = enum(u64) { http, https };

    pub fn init(
        allocator: Allocator,
        method: std.http.Method,
        path: []const u8,
        query: KVMap.List,
        headers: KVMap.List,
        payload: ?Payload,
    ) !Request {
        return .{
            .allocator = allocator,
            .method = method,
            .path = path,
            .query = try KVMap.init(allocator, query),
            .headers = try KVMap.init(allocator, headers),
            .payload = payload,
        };
    }

    pub fn deinit(self: *Request) void {
        self.query.deinit(self.allocator);
        self.headers.deinit(self.allocator);
    }

    pub fn addHeader(self: *Request, key: []const u8, value: []const u8) !void {
        try self.headers.add(self.allocator, key, value);
    }

    pub fn addHeaders(self: *Request, headers: KVMap.List) !void {
        try self.headers.addAll(self.allocator, headers);
    }

    pub fn payloadHash(self: Request) utils.HashStr {
        var hash: utils.HashStr = undefined;
        utils.hashString(&hash, if (self.payload) |p| p.content else null);
        return hash;
    }

    /// The caller owns the returned memory.
    pub fn queryString(self: Request, allocator: Allocator) ![]const u8 {
        var temp_buffer: QueryBuffer = undefined;
        var buffer_alloc = std.heap.FixedBufferAllocator.init(&temp_buffer);
        const temp_alloc = buffer_alloc.allocator();

        var count: usize = 0;
        var str_len: usize = 0;
        var kvs: HeadersKVBuffer = undefined;
        var it = self.query.iterator();
        while (it.next()) |kv| : (count += 1) {
            const key_fmt = try utils.escapeUri(temp_alloc, kv.key_ptr.*);
            const value_fmt = try utils.escapeUri(temp_alloc, kv.value_ptr.*);
            str_len += key_fmt.len + value_fmt.len;
            kvs[count] = .{ .key = key_fmt, .value = value_fmt };
        }
        std.sort.pdq(KVMap.Pair, kvs[0..count], {}, sortKeyValue);

        str_len += 2 * count -| 1; // `&`
        var stream = std.io.fixedBufferStream(try allocator.alloc(u8, str_len));
        errdefer self.allocator.free(stream.buffer);
        for (0..count) |i| {
            if (i > 0) try stream.writer().writeByte('&');
            const kv = kvs[i];
            try stream.writer().print("{s}={s}", .{ kv.key, kv.value });
        }
        assert(str_len == stream.pos);
        return stream.buffer;
    }

    /// The caller owns the returned memory.
    pub fn headersString(self: Request, allocator: Allocator) ![]const u8 {
        var temp_buffer: HeadersRawBuffer = undefined;
        var buffer_alloc = std.heap.FixedBufferAllocator.init(&temp_buffer);
        const temp_alloc = buffer_alloc.allocator();

        var count: usize = 0;
        var str_len: usize = 0;
        var kvs: HeadersKVBuffer = undefined;
        var it = self.headers.iterator();
        while (it.next()) |kv| : (count += 1) {
            const name_fmt = try std.ascii.allocLowerString(temp_alloc, kv.key_ptr.*);
            const value_fmt = std.mem.trim(u8, kv.value_ptr.*, &std.ascii.whitespace);
            str_len += name_fmt.len + value_fmt.len;
            kvs[count] = .{ .key = name_fmt, .value = value_fmt };
        }
        std.sort.pdq(KVMap.Pair, kvs[0..count], {}, sortKeyValue);

        str_len += 2 * count; // `:` `\n`
        var stream = std.io.fixedBufferStream(try allocator.alloc(u8, str_len));
        errdefer self.allocator.free(stream.buffer);
        for (0..count) |i| {
            const kv = kvs[i];
            try stream.writer().print("{s}:{s}\n", .{ kv.key, kv.value });
        }
        assert(str_len == stream.pos);
        return stream.buffer;
    }

    /// The caller owns the returned memory.
    pub fn headersNamesString(self: Request, allocator: Allocator) ![]const u8 {
        var temp_buffer: QueryBuffer = undefined;
        var buffer_alloc = std.heap.FixedBufferAllocator.init(&temp_buffer);
        const temp_alloc = buffer_alloc.allocator();

        var count: usize = 0;
        var str_len: usize = 0;
        var names: [MAX_HEADERS][]const u8 = undefined;
        for (self.headers.keys()) |name| {
            const name_fmt = try std.ascii.allocLowerString(temp_alloc, name);
            str_len += name_fmt.len;
            names[count] = name_fmt;
            count += 1;
        }
        std.sort.pdq([]const u8, names[0..count], {}, sortString);

        str_len += count -| 1; // `;`
        var stream = std.io.fixedBufferStream(try allocator.alloc(u8, str_len));
        for (names[0..count], 0..) |name, i| {
            if (i > 0) try stream.writer().writeByte(';');
            try stream.writer().writeAll(name);
        }
        assert(str_len == stream.pos);
        return stream.buffer;
    }

    fn sortKeyValue(_: void, lhs: KVMap.Pair, rhs: KVMap.Pair) bool {
        return std.ascii.lessThanIgnoreCase(lhs.key, rhs.key);
    }

    fn sortString(_: void, l: []const u8, r: []const u8) bool {
        return std.ascii.lessThanIgnoreCase(l, r);
    }
};

test "Request.addHeader" {
    var request = try testRequest(test_alloc);
    defer request.deinit();
    try request.addHeader("foo", "bar");
    try testing.expectEqualStrings("bar", request.headers.get("foo").?);
}

test "Request.addHeaders" {
    var request = try testRequest(test_alloc);
    defer request.deinit();
    try request.addHeaders(&.{
        .{ .key = "foo", .value = "bar" },
        .{ .key = "baz", .value = "qux" },
    });
    try testing.expectEqualStrings("bar", request.headers.get("foo").?);
    try testing.expectEqualStrings("qux", request.headers.get("baz").?);
}

test "Request.payloadHash" {
    var request = try testRequest(test_alloc);
    defer request.deinit();
    try testing.expectEqualStrings(
        "269dce1a5bb90188b2d9cf542a7c30e410c7d8251e34a97bfea56062df51ae23",
        &request.payloadHash(),
    );
}

test "Request.queryString" {
    var request = try testRequest(test_alloc);
    defer request.deinit();
    const query = try request.queryString(test_alloc);
    defer test_alloc.free(query);
    try testing.expectEqualStrings("baz=%24qux&foo=%25bar", query);
}

test "Request.headersString" {
    var request = try testRequest(test_alloc);
    defer request.deinit();
    const headers = try request.headersString(test_alloc);
    defer test_alloc.free(headers);
    try testing.expectEqualStrings(
        "host:s3.amazonaws.com\nx-amz-date:20130708T220855Z\n",
        headers,
    );
}

test "Request.headersNamesString" {
    var request = try testRequest(test_alloc);
    defer request.deinit();
    const names = try request.headersNamesString(test_alloc);
    defer test_alloc.free(names);
    try testing.expectEqualStrings("host;x-amz-date", names);
}

fn testRequest(allocator: Allocator) !Request {
    return Request.init(allocator, .GET, "/", &.{
        .{ .key = "foo", .value = "%bar" },
        .{ .key = "baz", .value = "$qux" },
    }, &.{
        .{ .key = "X-amz-date", .value = "20130708T220855Z" },
        .{ .key = "Host", .value = "s3.amazonaws.com" },
    }, .{
        .type = .json,
        .content = "foo-bar-baz",
    });
}

/// HTTP response content.
pub const Response = struct {
    allocator: Allocator,
    status: std.http.Status,
    // TODO: KV / HashMap (no need to dupe in client, since init will convert it from the stack)
    headers: []const u8,
    body: []const u8,

    pub fn deinit(self: Response) void {
        self.allocator.free(self.headers);
        self.allocator.free(self.body);
    }
};

pub const Payload = struct {
    type: ContentType,
    content: []const u8,

    pub const ContentType = union(enum) {
        text,
        xml,
        json,
        other: []const u8,
    };

    pub fn mime(self: Payload) []const u8 {
        return switch (self.type) {
            .text => "text/plain",
            .xml => "application/xml",
            .json => "application/json",
            .other => |m| m,
        };
    }
};

const KVMap = struct {
    pub const Pair = HashMap.KV;
    pub const List = []const Pair;
    const HashMap = std.StringArrayHashMapUnmanaged([]const u8);

    map: HashMap = .{},

    pub fn init(allocator: Allocator, list: List) !KVMap {
        var self = KVMap{ .map = .{} };
        try self.addAll(allocator, list);
        return self;
    }

    pub fn deinit(self: *KVMap, allocator: Allocator) void {
        self.map.deinit(allocator);
    }

    pub fn add(self: *KVMap, allocator: Allocator, key: []const u8, value: []const u8) !void {
        try self.map.put(allocator, key, value);
    }

    pub fn addAll(self: *KVMap, allocator: Allocator, list: List) !void {
        try self.map.ensureUnusedCapacity(allocator, list.len);
        for (list) |kv| self.map.putAssumeCapacity(kv.key, kv.value);
    }

    pub fn keys(self: KVMap) []const []const u8 {
        return self.map.keys();
    }

    pub fn iterator(self: KVMap) HashMap.Iterator {
        return self.map.iterator();
    }

    pub fn get(self: KVMap, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }
};

test "KVMap" {
    var map = KVMap{};
    defer map.deinit(test_alloc);

    try map.add(test_alloc, "foo", "107");
    try map.addAll(test_alloc, &.{
        .{ .key = "bar", .value = "108" },
        .{ .key = "qux", .value = "109" },
    });

    try testing.expectEqualDeep(&[_][]const u8{ "foo", "bar", "qux" }, map.keys());

    const it = map.iterator();
    try testing.expectEqualDeep(&[_][]const u8{ "foo", "bar", "qux" }, it.keys[0..3]);
    try testing.expectEqualDeep(&[_][]const u8{ "107", "108", "109" }, it.values[0..3]);

    try testing.expectEqualStrings("108", map.get("bar").?);
    try testing.expectEqual(null, map.get("baz"));

    map.deinit(test_alloc);
    map = try KVMap.init(test_alloc, &.{
        .{ .key = "foo", .value = "201" },
        .{ .key = "bar", .value = "203" },
    });
    try testing.expectEqualDeep(&[_][]const u8{ "foo", "bar" }, map.keys());
}
