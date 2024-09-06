const std = @import("std");
const ZigType = std.builtin.Type;
const testing = std.testing;
const Entry = @import("entries.zig").Entry;
const all_entries = @import("entries.zig").entries;

/// [AWS Spec](https://docs.aws.amazon.com/sdkref/latest/guide/settings-reference.html#EVarSettings)
const Env = struct {
    pub var shared: ?Values = null;

    pub fn load() !Values {
        return parse(std.os.environ);
    }

    pub fn loadCached() !Values {
        if (shared == null) shared = try parse(std.os.environ);
        return shared.?;
    }

    fn parse(lines: []const [*:0]const u8) !Values {
        var values: Values = .{};

        for (lines) |line| {
            var line_i: usize = 0;
            while (line[line_i] != 0 and line[line_i] != '=') : (line_i += 1) {}
            const key = line[0..line_i];

            const entry = entries.get(key) orelse continue;

            var end_i: usize = line_i;
            while (line[end_i] != 0) : (end_i += 1) {}
            const str_value = line[line_i + 1 .. end_i];

            inline for (comptime entries.values()) |e| {
                if (std.mem.eql(u8, e.field, entry.field)) {
                    if (e.parseFn) |parseFn| {
                        const T: type = @as(*const type, @ptrCast(@alignCast(e.Type))).*;
                        var out: T = undefined;
                        if (!parseFn(str_value, &out)) return error.EnvConfigParseFailed;
                        @field(values, e.field) = out;
                    } else {
                        @field(values, e.field) = str_value;
                    }
                    break;
                }
            }
        }

        return values;
    }

    const Values: type = blk: {
        var fields_len: usize = 0;
        var fields: [entries.kvs.len]ZigType.StructField = undefined;

        for (0..entries.kvs.len) |i| {
            const entry = entries.kvs.values[i];

            var name: [entry.field.len:0]u8 = undefined;
            @memcpy(name[0..entry.field.len], entry.field);

            const T: type = @as(*const type, @ptrCast(@alignCast(entry.Type))).*;
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

        break :blk @Type(.{ .Struct = .{
            .layout = .auto,
            .fields = fields[0..fields_len],
            .decls = &.{},
            .is_tuple = false,
        } });
    };
};

test "Env.parse" {
    try testing.expectEqualDeep(Env.Values{
        .ua_app_id = "baz",
        .retry_attempts = 3,
        .region = .us_east_2,
    }, try Env.parse(&[_][*:0]const u8{
        "FOO=bar",
        "AWS_SDK_UA_APP_ID=baz",
        "AWS_MAX_ATTEMPTS=3",
        "AWS_REGION=us-east-2",
    }));
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
