//! HTTP request configuration and content.
const std = @import("std");
const Uri = std.Uri;
const ArrayList = std.ArrayList(u8);
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const data = @import("data.zig");
const KVMap = data.KVMap;
const format = @import("format.zig");

pub const MAX_HEADERS = 1024;

const Self = @This();
const QueryBuffer = [1024]u8;
const HeadersRawBuffer = [4 * 1024]u8;
const HeadersKVBuffer = [MAX_HEADERS]KVMap.Pair;

allocator: Allocator,
method: std.http.Method,
path: []const u8,
query: KVMap,
headers: KVMap,
payload: ?data.Payload = null,

pub fn init(
    allocator: Allocator,
    method: std.http.Method,
    path: []const u8,
    query: KVMap.List,
    headers: KVMap.List,
    payload: ?data.Payload,
) !Self {
    return .{
        .allocator = allocator,
        .method = method,
        .path = path,
        .query = try KVMap.init(allocator, query),
        .headers = try KVMap.init(allocator, headers),
        .payload = payload,
    };
}

pub fn deinit(self: *Self) void {
    self.query.deinit(self.allocator);
    self.headers.deinit(self.allocator);
}

pub fn addHeader(self: *Self, key: []const u8, value: []const u8) !void {
    try self.headers.add(self.allocator, key, value);
}

test "addHeader" {
    var request = try testRequest(test_alloc);
    defer request.deinit();
    try request.addHeader("foo", "bar");
    try testing.expectEqualStrings("bar", request.headers.get("foo").?);
}

pub fn addHeaders(self: *Self, headers: KVMap.List) !void {
    try self.headers.addAll(self.allocator, headers);
}

test "addHeaders" {
    var request = try testRequest(test_alloc);
    defer request.deinit();
    try request.addHeaders(&.{
        .{ .key = "foo", .value = "bar" },
        .{ .key = "baz", .value = "qux" },
    });
    try testing.expectEqualStrings("bar", request.headers.get("foo").?);
    try testing.expectEqualStrings("qux", request.headers.get("baz").?);
}

pub fn payloadHash(self: Self) format.HashStr {
    var hash: format.HashStr = undefined;
    format.hashString(&hash, if (self.payload) |p| p.content else null);
    return hash;
}

test "payloadHash" {
    var request = try testRequest(test_alloc);
    defer request.deinit();
    try testing.expectEqualStrings(
        "269dce1a5bb90188b2d9cf542a7c30e410c7d8251e34a97bfea56062df51ae23",
        &request.payloadHash(),
    );
}

/// The caller owns the returned memory.
pub fn queryString(self: Self, allocator: Allocator) ![]const u8 {
    var temp_buffer: QueryBuffer = undefined;
    var buffer_alloc = std.heap.FixedBufferAllocator.init(&temp_buffer);
    const temp_alloc = buffer_alloc.allocator();

    var count: usize = 0;
    var str_len: usize = 0;
    var kvs: HeadersKVBuffer = undefined;
    var it = self.query.iterator();
    while (it.next()) |kv| : (count += 1) {
        const key_fmt = try Uri.escapeString(temp_alloc, kv.key_ptr.*);
        const value_fmt = try Uri.escapeString(temp_alloc, kv.value_ptr.*);
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
    std.debug.assert(str_len == stream.pos);
    return stream.buffer;
}

test "queryString" {
    var request = try testRequest(test_alloc);
    defer request.deinit();
    const query = try request.queryString(test_alloc);
    defer test_alloc.free(query);
    try testing.expectEqualStrings("baz=%24qux&foo=%25bar", query);
}

/// The caller owns the returned memory.
pub fn headersString(self: Self, allocator: Allocator) ![]const u8 {
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
    std.debug.assert(str_len == stream.pos);
    return stream.buffer;
}

test "headersString" {
    var request = try testRequest(test_alloc);
    defer request.deinit();
    const headers = try request.headersString(test_alloc);
    defer test_alloc.free(headers);
    try testing.expectEqualStrings(
        "host:s3.amazonaws.com\nx-amz-date:20130708T220855Z\n",
        headers,
    );
}

/// The caller owns the returned memory.
pub fn headersNamesString(self: Self, allocator: Allocator) ![]const u8 {
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
    std.sort.pdq([]const u8, names[0..count], {}, sortValue);

    str_len += count -| 1; // `;`
    var stream = std.io.fixedBufferStream(try allocator.alloc(u8, str_len));
    for (names[0..count], 0..) |name, i| {
        if (i > 0) try stream.writer().writeByte(';');
        try stream.writer().writeAll(name);
    }
    std.debug.assert(str_len == stream.pos);
    return stream.buffer;
}

test "headersNamesString" {
    var request = try testRequest(test_alloc);
    defer request.deinit();
    const names = try request.headersNamesString(test_alloc);
    defer test_alloc.free(names);
    try testing.expectEqualStrings("host;x-amz-date", names);
}

fn sortKeyValue(_: void, lhs: KVMap.Pair, rhs: KVMap.Pair) bool {
    return std.ascii.lessThanIgnoreCase(lhs.key, rhs.key);
}

fn sortValue(_: void, l: []const u8, r: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(l, r);
}

fn testRequest(allocator: Allocator) !Self {
    return Self.init(allocator, .GET, "/foo", &.{
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
