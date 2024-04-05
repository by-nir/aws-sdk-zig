const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;

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
