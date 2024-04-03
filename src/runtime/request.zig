const std = @import("std");
const Uri = std.Uri;
const ArrayList = std.ArrayList(u8);
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const Region = @import("aws-types").Region;

pub const RequestTarget = struct { region: Region, service: []const u8 };

pub const RequestContent = struct {
    const MAX_KV: usize = 16;
    pub const KV = struct { []const u8, []const u8 };

    method: std.http.Method,
    path: []const u8,
    query: []const u8,
    headers: []const u8,
    headers_names: []const u8,
    payload: ?[]const u8,

    pub fn init(
        allocator: Allocator,
        method: std.http.Method,
        path: []const u8,
        query: []const KV,
        headers: []const KV,
        payload: ?[]const u8,
    ) !RequestContent {
        var buffer = ArrayList.init(allocator);
        errdefer buffer.deinit();
        const query_str = try stringifyQuery(&buffer, allocator, query);
        errdefer allocator.free(query_str);
        const headers_str, const signed = try stringifyHeaders(&buffer, allocator, headers);
        return .{
            .method = method,
            .path = path,
            .query = query_str,
            .headers = headers_str,
            .headers_names = signed,
            .payload = payload,
        };
    }

    pub fn deinit(self: RequestContent, allocator: Allocator) void {
        allocator.free(self.query);
        allocator.free(self.headers);
        allocator.free(self.headers_names);
    }

    fn stringifyQuery(buffer: *ArrayList, allocator: Allocator, query_kvs: []const KV) ![]const u8 {
        var len: usize = 0;
        var kvs: [MAX_KV]KV = undefined;
        for (query_kvs) |kv| {
            const key, const value = kv;
            kvs[len] = .{
                try Uri.escapeString(allocator, key),
                try Uri.escapeString(allocator, value),
            };
            len += 1;
        }
        std.sort.pdq(KV, kvs[0..len], {}, sort);
        for (0..len) |i| {
            const key, const value = kvs[i];
            const prefix: []const u8 = if (i > 0) "&" else "";
            try buffer.writer().print("{s}{s}={s}", .{ prefix, key, value });
            allocator.free(key);
            allocator.free(value);
        }
        return buffer.toOwnedSlice();
    }

    fn stringifyHeaders(buffer: *ArrayList, allocator: Allocator, headers_kvs: []const KV) !KV {
        var len: usize = 0;
        var kvs: [MAX_KV]KV = undefined;
        for (headers_kvs) |kv| {
            const key, const value = kv;
            kvs[len] = .{
                try std.ascii.allocLowerString(allocator, key),
                std.mem.trim(u8, value, &std.ascii.whitespace),
            };
            len += 1;
        }
        std.sort.pdq(KV, kvs[0..len], {}, sort);
        for (0..len) |i| {
            const key, const value = kvs[i];
            try buffer.writer().print("{s}:{s}\n", .{ key, value });
        }
        const head = try buffer.toOwnedSlice();
        errdefer allocator.free(head);

        for (0..len) |i| {
            const key, _ = kvs[i];
            const prefix: []const u8 = if (i > 0) ";" else "";
            try buffer.writer().print("{s}{s}", .{ prefix, key });
            allocator.free(key);
        }
        const signed = try buffer.toOwnedSlice();
        return .{ head, signed };
    }

    fn sort(_: void, l: KV, r: KV) bool {
        const l_key, _ = l;
        const r_key, _ = r;
        return std.ascii.lessThanIgnoreCase(l_key, r_key);
    }
};

test "RequestContent" {
    const request = try RequestContent.init(test_alloc, .GET, "/foo", &.{
        .{ "foo", "%bar" },
        .{ "baz", "$qux" },
    }, &.{
        .{ "X-amz-date", "20130708T220855Z" },
        .{ "Host", "s3.amazonaws.com" },
    }, "foo-bar-baz");
    defer request.deinit(test_alloc);

    try testing.expectEqual(.GET, request.method);
    try testing.expectEqualStrings("/foo", request.path);
    try testing.expectEqualStrings("baz=%24qux&foo=%25bar", request.query);
    try testing.expectEqualStrings("host:s3.amazonaws.com\nx-amz-date:20130708T220855Z\n", request.headers);
    try testing.expectEqualStrings("host;x-amz-date", request.headers_names);
    try testing.expectEqualDeep("foo-bar-baz", request.payload);
}

pub const RequestTime = struct {
    /// Format: `yyyymmdd`
    date: [8]u8,
    /// Format: `yyyymmddThhmmssZ`
    timestamp: [16]u8,

    pub fn initNow() RequestTime {
        const secs: u64 = @intCast(std.time.timestamp());
        return initEpoch(secs);
    }

    /// `seconds` since the Unix epoch.
    pub fn initEpoch(seconds: u64) RequestTime {
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

test "RequestTime" {
    var buffer = ArrayList.init(test_alloc);
    defer buffer.deinit();

    const time = RequestTime.initEpoch(1373321335);
    try testing.expectEqualStrings("20130708", &time.date);
    try testing.expectEqualStrings("20130708T220855Z", &time.timestamp);
}
