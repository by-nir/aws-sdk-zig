const std = @import("std");
const stime = std.time;
const testing = std.testing;

const Self = @This();

/// A calendar timestamp, in milliseconds, relative to UTC 1970-01-01.
/// Precision of timing depends on the hardware and operating system.
/// The return value is signed because it is possible to have a date that is before the epoch.
epoch_ms: i64,

pub fn asMilliSigned(self: Self) i64 {
    return self.epoch_ms;
}

/// Assumes the timestamp is after UTC 1970-01-01.
pub fn asMilliUnsigned(self: Self) u64 {
    return @intCast(self.epoch_ms);
}

pub fn asSecSigned(self: Self) i64 {
    return @divTrunc(self.epoch_ms, stime.ms_per_s);
}

/// Assumes the timestamp is after UTC 1970-01-01.
pub fn asSecUnsigned(self: Self) u64 {
    return @intCast(@divTrunc(self.epoch_ms, stime.ms_per_s));
}

pub fn asSecFloat(self: Self) f64 {
    return @as(f64, @floatFromInt(self.epoch_ms)) / stime.ms_per_s;
}

test {
    const ts = Self{ .epoch_ms = 1515531081123 };
    try testing.expectEqual(1515531081123, ts.asMilliSigned());
    try testing.expectEqual(1515531081123, ts.asMilliUnsigned());
    try testing.expectEqual(1515531081, ts.asSecSigned());
    try testing.expectEqual(1515531081, ts.asSecUnsigned());
    try testing.expectEqual(1515531081.123, ts.asSecFloat());
}
