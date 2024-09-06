const std = @import("std");
const testing = std.testing;

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
