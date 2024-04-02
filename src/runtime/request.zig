const std = @import("std");
const AnyWriter = std.io.AnyWriter;
const testing = std.testing;
const test_alloc = testing.allocator;
const types = @import("aws-types");
const Region = types.Region;

pub const RequestTarget = struct {
    region: Region,
    service: []const u8,
    endpoint: RequestEndpoint,
};

pub const RequestContent = struct {
    method: std.http.Method,
    query: []const Pair,
    headers: []const Pair,
    payload: ?[]const u8,

    pub const Pair = struct {
        key: []const u8,
        value: []const u8,

        fn sort(_: void, l: Pair, r: Pair) bool {
            return std.ascii.lessThanIgnoreCase(l.key, r.key);
        }
    };
};

pub const RequestTime = struct {
    year: u16,
    month: std.time.epoch.MonthAndDay,
    day: std.time.epoch.DaySeconds,

    pub fn initNow() !RequestTime {
        const secs: u64 = @intCast(std.time.timestamp());
        return initEpoch(secs);
    }

    /// `seconds` since the Unix epoch.
    pub fn initEpoch(seconds: u64) !RequestTime {
        const epoch_sec = std.time.epoch.EpochSeconds{ .secs = seconds };
        const year_day = epoch_sec.getEpochDay().calculateYearDay();
        return .{
            .year = year_day.year,
            .month = year_day.calculateMonthDay(),
            .day = epoch_sec.getDaySeconds(),
        };
    }

    /// Format: `yyyymmdd`
    pub fn writeDate(self: RequestTime, writer: AnyWriter) !void {
        try writer.print(
            "{d:4}{d:0>2}{d:0>2}",
            .{ self.year, self.month.month.numeric(), self.month.day_index + 1 },
        );
    }

    /// Format: `yyyymmddThhmmssZ`
    ///
    /// An error may accure after partially writing the date; the caller should
    /// rollback any partial writes.
    pub fn writeTime(self: RequestTime, writer: AnyWriter) !void {
        try self.writeDate(writer);
        try writer.print(
            "T{d:0>2}{d:0>2}{d:0>2}Z",
            .{ self.day.getHoursIntoDay(), self.day.getMinutesIntoHour(), self.day.getSecondsIntoMinute() },
        );
    }
};

test "RequestTime" {
    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();

    const req = try RequestTime.initEpoch(1373321335);
    try req.writeDate(buffer.writer().any());
    try testing.expectEqualStrings("20130708", buffer.items);

    buffer.clearRetainingCapacity();
    try req.writeTime(buffer.writer().any());
    try testing.expectEqualStrings("20130708T220855Z", buffer.items);
}

pub const RequestProtocol = enum(u64) {
    https,
};

/// [AWS Docs](https://docs.aws.amazon.com/general/latest/gr/rande.html)
pub const RequestEndpoint = struct {
    host: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        stack: Stack,
        service: []const u8,
        region: ?Region,
    ) !RequestEndpoint {
        const domain: []const u8 = switch (stack) {
            .dual_only => ".amazonaws.com",
            .dual_or_single => ".api.aws",
        };

        var i: usize = 0;
        var host: []u8 = undefined;
        if (region) |r| {
            const code = r.code();
            i = code.len + 1;
            host = try allocator.alloc(u8, i + service.len + domain.len);
            @memcpy(host[0..code.len], code);
            host[code.len] = '.';
        } else {
            host = try allocator.alloc(u8, service.len + domain.len);
        }

        @memcpy(host[i..][0..service.len], service);
        @memcpy(host[i + service.len ..][0..domain.len], domain);
        return .{ .host = host };
    }

    pub fn deinit(self: RequestEndpoint, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
    }

    pub fn writeHostname(self: RequestEndpoint, writer: AnyWriter, protocol: RequestProtocol) !void {
        try writer.print("{s}://{s}", .{ @tagName(protocol), self.host });
    }

    /// Some AWS services offer dual stack endpoints, so that you can access them using either IPv4 or IPv6 requests.
    ///
    /// [AWS Docs](https://docs.aws.amazon.com/general/latest/gr/rande.html#dual-stack-endpoints)
    pub const Stack = enum {
        /// Services that offer only dual stack endpoints.
        dual_only,
        /// Services that offer both single and dual stack endpoints.
        dual_or_single,
    };
};

test "RequestEndpoint" {
    var ep = try RequestEndpoint.init(test_alloc, .dual_or_single, "s3", null);
    errdefer ep.deinit(test_alloc);
    try testing.expectEqualStrings("s3.api.aws", ep.host);
    ep.deinit(test_alloc);

    ep = try RequestEndpoint.init(test_alloc, .dual_only, "s3", Region.us_east_1);
    try testing.expectEqualStrings("us-east-1.s3.amazonaws.com", ep.host);

    var buffer = std.ArrayList(u8).init(test_alloc);
    defer buffer.deinit();
    try ep.writeHostname(buffer.writer().any(), .https);
    try testing.expectEqualStrings("https://us-east-1.s3.amazonaws.com", buffer.items);
    ep.deinit(test_alloc);
}
