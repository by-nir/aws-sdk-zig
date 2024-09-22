//! https://docs.aws.amazon.com/sdkref/latest/guide/settings-reference.html#EVarSettings
const std = @import("std");
const ZigType = std.builtin.Type;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const Entry = @import("entries.zig").Entry;
const all_entries = @import("entries.zig").entries;
const SharedResource = @import("../utils/SharedResource.zig");

var tracker = SharedResource{};
var shared_aws: AwsEnv = undefined;
var shared_raw: std.process.EnvMap = undefined;

pub fn loadEnvironment(allocator: Allocator) !AwsEnv {
    try tracker.retainCallback(onLoad, allocator);
    return shared_aws;
}

pub fn releaseEnvironment() void {
    tracker.releaseCallback(onRelease, {});
}

/// Assumes values were previously loaded.
pub fn readValue(comptime field: std.meta.FieldEnum(AwsEnv)) std.meta.FieldType(AwsEnv, field) {
    std.debug.assert(tracker.countSafe() > 0);
    return @field(shared_aws, @tagName(field));
}

/// Assumes values were previously loaded.
pub fn overrideValue(comptime field: std.meta.FieldEnum(AwsEnv), value: std.meta.FieldType(AwsEnv, field)) void {
    std.debug.assert(tracker.countSafe() > 0);
    @field(shared_aws, @tagName(field)) = value;
}

fn onRelease(_: void) void {
    shared_raw.deinit();
    shared_raw = undefined;
    shared_aws = undefined;
}

fn onLoad(allocator: Allocator) !void {
    shared_raw = try std.process.getEnvMap(allocator);
    errdefer {
        shared_raw.deinit();
        shared_raw = undefined;
    }

    shared_aws = .{};
    errdefer shared_aws = undefined;

    var it = shared_raw.iterator();
    while (it.next()) |pair| {
        const key = pair.key_ptr.*;
        const entry = entries.get(key) orelse continue;

        inline for (comptime entries.values()) |e| {
            if (std.mem.eql(u8, e.field, entry.field)) {
                const str_val = pair.value_ptr.*;
                @field(shared_aws, e.field) = try e.parse(str_val);
                break;
            }
        }
    }
}

const AwsEnv: type = blk: {
    var fields_len: usize = 0;
    var fields: [entries.kvs.len]ZigType.StructField = undefined;

    for (0..entries.kvs.len) |i| {
        const entry = entries.kvs.values[i];

        var name: [entry.field.len:0]u8 = undefined;
        @memcpy(name[0..entry.field.len], entry.field);

        const T = entry.Type();
        const default_value: ?T = null;
        fields[fields_len] = ZigType.StructField{
            .name = &name,
            .type = ?T,
            .default_value = &default_value,
            .is_comptime = false,
            .alignment = @alignOf(?T),
        };
        fields_len += 1;
    }

    break :blk @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = fields[0..fields_len],
        .decls = &.{},
        .is_tuple = false,
    } });
};

test {
    _ = try loadEnvironment(test_alloc);
    defer releaseEnvironment();

    try testing.expectEqual(null, readValue(.ua_app_id));
    overrideValue(.ua_app_id, "foo");
    try testing.expectEqual("foo", readValue(.ua_app_id));

    const env = loadEnvironment(test_alloc);
    defer releaseEnvironment();

    try testing.expectEqualDeep(AwsEnv{
        .ua_app_id = "foo",
    }, env);
}

const entries: std.StaticStringMap(Entry) = blk: {
    var map_len: usize = 0;
    var map: [all_entries.len]struct { []const u8, Entry } = undefined;

    for (all_entries) |entry| {
        if (entry.key_env == null) continue;
        map[map_len] = .{ entry.key_env.?, entry };
        map_len += 1;
    }

    break :blk std.StaticStringMap(Entry).initComptime(map[0..map_len]);
};
