//! UTC time string.
const std = @import("std");
const testing = std.testing;

const Self = @This();
pub const Date = *const [8]u8;
pub const Timestamp = *const [16]u8;

value: [16]u8,

pub fn now() Self {
    const secs: u64 = @intCast(std.time.timestamp());
    return sinceEpoch(secs);
}

/// Seconds since the Unix epoch.
pub fn sinceEpoch(seconds: u64) Self {
    const epoch_sec = std.time.epoch.EpochSeconds{ .secs = seconds };
    const year_day = epoch_sec.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch_sec.getDaySeconds();

    var self: Self = undefined;
    _ = std.fmt.bufPrint(&self.value, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch unreachable;

    return self;
}

/// Format: `yyyymmdd`
pub fn date(self: *const Self) Date {
    return self.value[0..8];
}

/// Format: `yyyymmddThhmmssZ`
pub fn timestamp(self: *const Self) Timestamp {
    return &self.value;
}

test {
    const time = Self.sinceEpoch(1373321335);
    try testing.expectEqualStrings("20130708", time.date());
    try testing.expectEqualStrings("20130708T220855Z", time.timestamp());
}
