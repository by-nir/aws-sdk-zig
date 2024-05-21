const std = @import("std");
const Uri = std.Uri;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const format = @import("format.zig");

pub const MAX_HEADERS = 1024;

const QueryBuffer = [1024]u8;
const HeadersRawBuffer = [4 * 1024]u8;
const HeadersKVBuffer = [MAX_HEADERS]KVMap.Pair;

/// HTTP request configuration and content.
pub const Request = struct {
    allocator: Allocator,
    method: std.http.Method,
    path: []const u8,
    query: KVMap,
    headers: KVMap,
    payload: ?Payload = null,

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

    pub fn payloadHash(self: Request) format.HashStr {
        var hash: format.HashStr = undefined;
        format.hashString(&hash, if (self.payload) |p| p.content else null);
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
            const key_fmt = try format.escapeUri(temp_alloc, kv.key_ptr.*);
            const value_fmt = try format.escapeUri(temp_alloc, kv.value_ptr.*);
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
        std.debug.assert(str_len == stream.pos);
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
        std.debug.assert(str_len == stream.pos);
        return stream.buffer;
    }

    fn sortKeyValue(_: void, lhs: KVMap.Pair, rhs: KVMap.Pair) bool {
        return std.ascii.lessThanIgnoreCase(lhs.key, rhs.key);
    }

    fn sortString(_: void, l: []const u8, r: []const u8) bool {
        return std.ascii.lessThanIgnoreCase(l, r);
    }
};

test "addHeader" {
    var request = try testRequest(test_alloc);
    defer request.deinit();
    try request.addHeader("foo", "bar");
    try testing.expectEqualStrings("bar", request.headers.get("foo").?);
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

test "payloadHash" {
    var request = try testRequest(test_alloc);
    defer request.deinit();
    try testing.expectEqualStrings(
        "269dce1a5bb90188b2d9cf542a7c30e410c7d8251e34a97bfea56062df51ae23",
        &request.payloadHash(),
    );
}

test "queryString" {
    var request = try testRequest(test_alloc);
    defer request.deinit();
    const query = try request.queryString(test_alloc);
    defer test_alloc.free(query);
    try testing.expectEqualStrings("baz=%24qux&foo=%25bar", query);
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

test "headersNamesString" {
    var request = try testRequest(test_alloc);
    defer request.deinit();
    const names = try request.headersNamesString(test_alloc);
    defer test_alloc.free(names);
    try testing.expectEqualStrings("host;x-amz-date", names);
}

fn testRequest(allocator: Allocator) !Request {
    return Request.init(allocator, .GET, "/foo", &.{
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
    headers: []const u8,
    body: []const u8,

    pub fn deinit(self: Response) void {
        self.allocator.free(self.headers);
        self.allocator.free(self.body);
    }
};

pub const KVMap = struct {
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

pub const TimeStr = struct {
    /// Format: `yyyymmdd`
    date: [8]u8,
    /// Format: `yyyymmddThhmmssZ`
    timestamp: [16]u8,

    pub fn initNow() TimeStr {
        const secs: u64 = @intCast(std.time.timestamp());
        return initEpoch(secs);
    }

    /// `seconds` since the Unix epoch.
    pub fn initEpoch(seconds: u64) TimeStr {
        const epoch_sec = std.time.epoch.EpochSeconds{ .secs = seconds };
        const year_day = epoch_sec.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_secs = epoch_sec.getDaySeconds();

        var date: [8]u8 = undefined;
        formatInt(date[0..4], year_day.year);
        formatInt(date[4..6], month_day.month.numeric());
        formatInt(date[6..8], month_day.day_index + 1);

        var timestamp: [16]u8 = "00000000T000000Z".*;
        @memcpy(timestamp[0..8], &date);
        formatInt(timestamp[9..11], day_secs.getHoursIntoDay());
        formatInt(timestamp[11..13], day_secs.getMinutesIntoHour());
        formatInt(timestamp[13..15], day_secs.getSecondsIntoMinute());

        return .{ .date = date, .timestamp = timestamp };
    }

    fn formatInt(out: []u8, value: anytype) void {
        _ = std.fmt.formatIntBuf(out, value, 10, .lower, .{
            .width = out.len,
            .fill = '0',
        });
    }
};

test "TimeStr" {
    const time = TimeStr.initEpoch(1373321335);
    try testing.expectEqualStrings("20130708", &time.date);
    try testing.expectEqualStrings("20130708T220855Z", &time.timestamp);
}
