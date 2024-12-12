const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const Allocator = mem.Allocator;
const stime = std.time;
const testing = std.testing;
const test_alloc = testing.allocator;

pub const SerialType = enum {
    boolean,
    byte,
    short,
    integer,
    long,
    float,
    double,
    blob,
    string,
    timestamp_date_time,
    timestamp_http_date,
    timestamp_epoch_seconds,
    big_integer,
    big_decimal,
    map,
    set,
    list_dense,
    list_sparse,
    int_enum,
    str_enum,
    trt_enum,
    tagged_union,
    structure,
    document,
};

pub const MetaLabel = enum {
    path_shape,
};

pub const MetaParam = enum {
    header_map,
    header_shape,
    header_base64,
    query_map,
    query_shape,
};

pub const MetaPayload = enum {
    media,
    shape,
};

pub const MetaTransport = enum {
    status_code,
};

pub fn uriEncode(allocator: Allocator, value: []const u8) ![]const u8 {
    const encoder = UriEncoder(false){ .raw = value };
    return fmt.allocPrint(allocator, "{}", .{encoder});
}

test uriEncode {
    const escaped = try uriEncode(test_alloc, ":/?#[]@!$&'()*+,;=%");
    defer test_alloc.free(escaped);
    try testing.expectEqualStrings("%3A%2F%3F%23%5B%5D%40%21%24%26%27%28%29%2A%2B%2C%3B%3D%25", escaped);
}

// https://github.com/smithy-lang/smithy-rs/blob/main/rust-runtime/aws-smithy-http/src/urlencode.rs
pub fn UriEncoder(comptime greedy: bool) type {
    return struct {
        raw: []const u8,

        pub fn format(self: @This(), comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
            var start: usize = 0;
            for (self.raw, 0..) |char, index| {
                if (isValidUrlChar(char)) continue;
                try writer.print("{s}%{X:0>2}", .{ self.raw[start..index], char });
                start = index + 1;
            }
            try writer.writeAll(self.raw[start..]);
        }

        fn isValidUrlChar(char: u8) bool {
            return switch (char) {
                '/' => greedy,
                // zig fmt: off
                ' ', ':', ',', '?', '#', '[', ']', '{', '}', '|', '@', '!', '$', '&',
                '\'', '(', ')', '*', '+', ';', '=', '%', '<', '>', '"', '^', '`', '\\' => false,
                // zig fmt: on
                else => !std.ascii.isControl(char),
            };
        }
    };
}

/// Timestamp as defined by the date-time production in RFC 3339 (section 5.6),
/// with optional millisecond precision but no UTC offset.
///
/// Assumes valid input. Does not account for leap seconds.
/// ```
/// 1985-04-12T23:20:50.520Z
/// ```
pub fn parseTimestamp(s: []const u8) !i64 {
    var parts = TimeParts{};

    const date = s[0..mem.indexOfAny(u8, s, "Tt").?];
    {
        var it = mem.splitScalar(u8, date, '-');
        parts.year = try fmt.parseUnsigned(u13, it.next().?, 10);
        parts.month = try fmt.parseUnsigned(u4, it.next().?, 10);
        parts.day = try fmt.parseUnsigned(u5, it.next().?, 10);
        std.debug.assert(it.next() == null);
    }

    const time = s[date.len + 1 .. mem.indexOfAnyPos(u8, s, date.len + 1, "Zz").?];
    {
        var it = mem.splitAny(u8, time, ":.");
        parts.hour = try fmt.parseUnsigned(u5, it.next().?, 10);
        parts.minute = try fmt.parseUnsigned(u6, it.next().?, 10);
        parts.second = try fmt.parseUnsigned(u6, it.next().?, 10);
        if (it.next()) |frac| {
            const len = @min(frac.len, 3);
            var frac_pad: [3]u8 = "000".*;
            @memcpy(frac_pad[0..len], frac[0..len]);
            parts.millisecond = try fmt.parseUnsigned(u10, &frac_pad, 10);
        }
    }

    return parts.toEpochMs();
}

test parseTimestamp {
    try testing.expectEqual(482196050000, try parseTimestamp("1985-04-12T23:20:50Z"));
    try testing.expectEqual(482196050520, try parseTimestamp("1985-04-12T23:20:50.52Z"));
}

pub const timestamp_buffer_len = 24;

pub fn writeTimestamp(writer: std.io.AnyWriter, epoch_ms: i64) !void {
    const t = TimeParts.fromEpochMs(epoch_ms);
    const format = "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}";
    if (t.millisecond > 0) {
        const args = .{ t.year, t.month, t.day, t.hour, t.minute, t.second, t.millisecond };
        try writer.print(format ++ ".{d:0>3}Z", args);
    } else {
        const args = .{ t.year, t.month, t.day, t.hour, t.minute, t.second };
        try writer.print(format ++ "Z", args);
    }
}

test writeTimestamp {
    var buf: [timestamp_buffer_len]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    try writeTimestamp(stream.writer().any(), 482196050520);
    try testing.expectEqualStrings("1985-04-12T23:20:50.520Z", stream.getWritten());

    stream.reset();
    try writeTimestamp(stream.writer().any(), 482196050000);
    try testing.expectEqualStrings("1985-04-12T23:20:50Z", stream.getWritten());
}

/// An HTTP date as defined by the IMF-fixdate production in RFC 7231 (section 7.1.1.1).
///
/// STRICTLY assumes valid input. Does not account for leap seconds.
/// ```
/// Tue, 29 Apr 2014 18:30:38 GMT
/// ```
pub fn parseHttpDate(s: []const u8) !i64 {
    const month: u4 = switch (s[8]) {
        'F' => 2,
        'S' => 9,
        'O' => 10,
        'N' => 11,
        'D' => 12,
        'A' => switch (s[9]) {
            'p' => 4,
            'u' => 8,
            else => unreachable,
        },
        'M' => switch (s[10]) {
            'r' => 3,
            'y' => 5,
            else => unreachable,
        },
        'J' => switch (s[9]) {
            'a' => 1,
            'u' => switch (s[10]) {
                'n' => 6,
                'l' => 7,
                else => unreachable,
            },
            else => unreachable,
        },
        else => unreachable,
    };

    const parts = TimeParts{
        .year = try fmt.parseUnsigned(u13, s[12..16], 10),
        .month = month,
        .day = try fmt.parseUnsigned(u5, s[5..7], 10),
        .hour = try fmt.parseUnsigned(u5, s[17..19], 10),
        .minute = try fmt.parseUnsigned(u6, s[20..22], 10),
        .second = try fmt.parseUnsigned(u6, s[23..25], 10),
    };
    return parts.toEpochMs();
}

test parseHttpDate {
    try testing.expectEqual(1398796238000, try parseHttpDate("Tue, 29 Apr 2014 18:30:38 GMT"));
    try testing.expectEqual(784111777000, try parseHttpDate("Sun, 06 Nov 1994 08:49:37 GMT"));
}

pub const http_date_buffer_len = 29;

pub fn writeHttpDate(writer: std.io.AnyWriter, epoch_ms: i64) !void {
    const weekdays = [7][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const months = [12][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

    const t = TimeParts.fromEpochMs(epoch_ms);
    const month = months[t.month - 1];
    const weekday = weekdays[t.toWeekdayIndex()];
    try writer.print(
        "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT",
        .{ weekday, t.day, month, t.year, t.hour, t.minute, t.second },
    );
}

test writeHttpDate {
    var buf: [http_date_buffer_len]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    try writeHttpDate(stream.writer().any(), 1398796238000);
    try testing.expectEqualStrings("Tue, 29 Apr 2014 18:30:38 GMT", stream.getWritten());

    stream.reset();
    try writeHttpDate(stream.writer().any(), 784111777000);
    try testing.expectEqualStrings("Sun, 06 Nov 1994 08:49:37 GMT", stream.getWritten());
}

const TimeParts = struct {
    year: u13 = 0,
    /// Month of the year (1-12)
    month: u4 = 0,
    /// Day of the month (1-31)
    day: u5 = 0,
    /// 24-hour clock (0-23)
    hour: u5 = 0,
    minute: u6 = 0,
    second: u6 = 0,
    millisecond: u10 = 0,

    /// Only valid for dates after 1970-01-01.
    pub fn fromEpochMs(epoch_ms: i64) TimeParts {
        std.debug.assert(epoch_ms >= 0);
        const round = @divTrunc(epoch_ms, stime.ms_per_s);
        const epoch = stime.epoch.EpochSeconds{ .secs = @intCast(round) };
        const epoch_year = epoch.getEpochDay().calculateYearDay();
        const epoch_month = epoch_year.calculateMonthDay();
        const epoch_secs = epoch.getDaySeconds();

        return TimeParts{
            .year = @intCast(epoch_year.year),
            .month = epoch_month.month.numeric(),
            .day = epoch_month.day_index + 1,
            .hour = epoch_secs.getHoursIntoDay(),
            .minute = epoch_secs.getMinutesIntoHour(),
            .second = epoch_secs.getSecondsIntoMinute(),
            .millisecond = @intCast(epoch_ms - round * stime.ms_per_s),
        };
    }

    /// Computes **ms** since the UNIX epoch.
    pub fn toEpochMs(self: TimeParts) i64 {
        // Convert days to seconds
        var total_seconds: i64 = self.countDays() * stime.s_per_day;

        // Current time
        total_seconds += @as(i64, @intCast(self.hour)) * stime.s_per_hour;
        total_seconds += @as(i64, @intCast(self.minute)) * stime.s_per_min;
        total_seconds += self.second;

        // Milliseconds
        return (total_seconds * stime.ms_per_s) + self.millisecond;
    }

    fn countDays(self: TimeParts) i64 {
        var total_days: i64 = 0;

        // Previous years
        const years_after = @as(i64, @intCast(self.year)) - 1970;
        total_days += years_after * 365;

        // Leap years
        total_days += countPriorLeaps(self.year) - countPriorLeaps(1970);

        // Previous months
        const is_leap = stime.epoch.isLeapYear(self.year);
        total_days += countCumulativeDays(self.month, is_leap);

        // Current month
        return total_days + (self.day - 1);
    }

    fn countPriorLeaps(year: u13) i64 {
        const y = year -| 1; // Exclude current year
        return (y / 4) - (y / 100) + (y / 400);
    }

    fn countCumulativeDays(calender_month: u4, is_leap: bool) u9 {
        const cumul_leap: []const u9 = &.{ 0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335 };
        const cumul_common: []const u9 = &.{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };
        const days = if (is_leap) cumul_leap else cumul_common;
        return days[calender_month - 1];
    }

    pub fn toWeekdayIndex(self: TimeParts) u3 {
        const days = self.countDays();
        const index = @mod(days + 4, 7); // 1970-01-01 was a Thursday
        return @intCast(index);
    }
};

test TimeParts {
    try testing.expectEqual(TimeParts{
        .year = 1985,
        .month = 4,
        .day = 12,
        .hour = 23,
        .minute = 20,
        .second = 50,
        .millisecond = 520,
    }, TimeParts.fromEpochMs(482196050520));

    var parts = TimeParts{
        .year = 1985,
        .month = 4,
        .day = 12,
        .hour = 23,
        .minute = 20,
        .second = 50,
        .millisecond = 520,
    };
    try testing.expectEqual(482196050520, parts.toEpochMs());
    try testing.expectEqual(5, parts.toWeekdayIndex());

    parts = TimeParts{
        .year = 1920,
        .month = 4,
        .day = 12,
        .hour = 23,
        .minute = 20,
        .second = 50,
        .millisecond = 520,
    };
    try testing.expectEqual(-1569026349480, parts.toEpochMs());
    try testing.expectEqual(1, parts.toWeekdayIndex());
}

pub fn findMemberIndex(comptime members: anytype, key: []const u8) ?usize {
    inline for (members, 0..) |member, i| {
        if (mem.eql(u8, member.name_api, key)) return i;
    }
    return null;
}
