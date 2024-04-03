//! HTTP request configuration and content.

const std = @import("std");
const Uri = std.Uri;
const ArrayList = std.ArrayList(u8);
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const format = @import("format.zig");

const MAX_KV: usize = 16;

const Self = @This();
const QueryBuffer = [1024]u8;
const HeadersBuffer = [4 * 1024]u8;
pub const KV = struct { []const u8, []const u8 };

method: std.http.Method,
path: []const u8,
query: []const KV,
headers: []const KV,
payload: ?[]const u8,

pub fn payloadHash(self: Self) format.HashStr {
    var hash: format.HashStr = undefined;
    format.hashString(&hash, self.payload);
    return hash;
}

test "payloadHash" {
    try testing.expectEqualStrings(
        "269dce1a5bb90188b2d9cf542a7c30e410c7d8251e34a97bfea56062df51ae23",
        &TEST_REQUEST.payloadHash(),
    );
}

/// The caller owns the returned slice.
pub fn queryString(self: Self, allocator: Allocator) ![]const u8 {
    var temp_buffer: QueryBuffer = undefined;
    var buffer_alloc = std.heap.FixedBufferAllocator.init(&temp_buffer);
    const temp_alloc = buffer_alloc.allocator();

    var count: usize = 0;
    var str_len: usize = 0;
    var kvs: [MAX_KV]KV = undefined;
    for (self.query) |kv| {
        const key, const value = kv;
        const key_fmt = try Uri.escapeString(temp_alloc, key);
        const value_fmt = try Uri.escapeString(temp_alloc, value);
        str_len += key_fmt.len + value_fmt.len;
        kvs[count] = .{ key_fmt, value_fmt };
        count += 1;
    }
    std.sort.pdq(KV, kvs[0..count], {}, sortKeyValue);

    str_len += 2 * count -| 1; // `&`
    var stream = std.io.fixedBufferStream(try allocator.alloc(u8, str_len));
    errdefer allocator.free(stream.buffer);
    for (0..count) |i| {
        if (i > 0) try stream.writer().writeByte('&');
        const key, const value = kvs[i];
        try stream.writer().print("{s}={s}", .{ key, value });
    }
    std.debug.assert(str_len == stream.pos);
    return stream.buffer;
}

test "queryString" {
    const query = try TEST_REQUEST.queryString(test_alloc);
    defer test_alloc.free(query);
    try testing.expectEqualStrings("baz=%24qux&foo=%25bar", query);
}

pub fn headersString(self: Self, allocator: Allocator) ![]const u8 {
    var temp_buffer: HeadersBuffer = undefined;
    var buffer_alloc = std.heap.FixedBufferAllocator.init(&temp_buffer);
    const temp_alloc = buffer_alloc.allocator();

    var count: usize = 0;
    var str_len: usize = 0;
    var kvs: [MAX_KV]KV = undefined;
    for (self.headers) |kv| {
        const name, const value = kv;
        const name_fmt = try std.ascii.allocLowerString(temp_alloc, name);
        const value_fmt = std.mem.trim(u8, value, &std.ascii.whitespace);
        str_len += name_fmt.len + value_fmt.len;
        kvs[count] = .{ name_fmt, value_fmt };
        count += 1;
    }
    std.sort.pdq(KV, kvs[0..count], {}, sortKeyValue);

    str_len += 2 * count; // `:` `\n`
    var stream = std.io.fixedBufferStream(try allocator.alloc(u8, str_len));
    errdefer allocator.free(stream.buffer);
    for (0..count) |i| {
        const key, const value = kvs[i];
        try stream.writer().print("{s}:{s}\n", .{ key, value });
    }
    std.debug.assert(str_len == stream.pos);
    return stream.buffer;
}

test "headersString" {
    const headers = try TEST_REQUEST.headersString(test_alloc);
    defer test_alloc.free(headers);
    try testing.expectEqualStrings("host:s3.amazonaws.com\nx-amz-date:20130708T220855Z\n", headers);
}

pub fn headersNamesString(self: Self, allocator: Allocator) ![]const u8 {
    var temp_buffer: QueryBuffer = undefined;
    var buffer_alloc = std.heap.FixedBufferAllocator.init(&temp_buffer);
    const temp_alloc = buffer_alloc.allocator();

    var count: usize = 0;
    var str_len: usize = 0;
    var names: [MAX_KV][]const u8 = undefined;
    for (self.headers) |kv| {
        const name, _ = kv;
        const name_fmt = try std.ascii.allocLowerString(temp_alloc, name);
        str_len += name_fmt.len;
        names[count] = name_fmt;
        count += 1;
    }
    std.sort.pdq([]const u8, names[0..count], {}, sortValue);

    str_len += count -| 1; // `;`
    var stream = std.io.fixedBufferStream(try allocator.alloc(u8, str_len));
    errdefer allocator.free(stream.buffer);
    for (names[0..count], 0..) |name, i| {
        if (i > 0) try stream.writer().writeByte(';');
        try stream.writer().writeAll(name);
    }
    std.debug.assert(str_len == stream.pos);
    return stream.buffer;
}

test "headersNamesString" {
    const names = try TEST_REQUEST.headersNamesString(test_alloc);
    defer test_alloc.free(names);
    try testing.expectEqualStrings("host;x-amz-date", names);
}

fn sortKeyValue(_: void, l: KV, r: KV) bool {
    const l_key, _ = l;
    const r_key, _ = r;
    return std.ascii.lessThanIgnoreCase(l_key, r_key);
}

fn sortValue(_: void, l: []const u8, r: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(l, r);
}

const TEST_REQUEST = Self{
    .method = .GET,
    .path = "/foo",
    .query = &.{
        .{ "foo", "%bar" },
        .{ "baz", "$qux" },
    },
    .headers = &.{
        .{ "X-amz-date", "20130708T220855Z" },
        .{ "Host", "s3.amazonaws.com" },
    },
    .payload = "foo-bar-baz",
};
