//! https://smithy.io/2.0/spec/http-bindings.html
const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const Allocator = mem.Allocator;
const smithy = @import("smithy/runtime");
const srlz = smithy.serial;
const Request = @import("../http.zig").Request;
const Response = @import("../http.zig").Response;

const log = std.log.scoped(.aws_sdk);

pub fn uriMetaLabels(
    allocator: Allocator,
    comptime labels: anytype,
    comptime members: anytype,
    comptime path: []const u8,
    input: anytype,
) ![]const u8 {
    const fmt_str, const Args, const args_indices = comptime blk: {
        var fmt_len: usize = 0;
        var fmt_str: [path.len]u8 = undefined;
        var args_indices: [labels.len]usize = undefined;
        var args_fields: [labels.len]std.builtin.Type.StructField = undefined;

        var args_len: usize = 0;
        var it = mem.tokenizeScalar(u8, path, '/');
        while (it.next()) |part| {
            if (part[0] != '{') {
                fmt_str[fmt_len] = '/';
                @memcpy(fmt_str[fmt_len + 1 ..][0..part.len], part);
                fmt_len += 1 + part.len;
                continue;
            }

            const is_greedy = part[part.len - 2] == '+';
            const label = part[1 .. part.len - (if (is_greedy) 2 else 1)];
            for (labels, 0..) |meta, i| {
                if (meta[0] != smithy.MetaParam.path_shape) continue;

                const member = members[meta[1]];
                const scheme = member[3];
                if (!mem.eql(u8, label, member[0])) continue;

                const fmt_part, const arg_typ = switch (@as(smithy.SerialType, scheme[0])) {
                    .boolean,
                    // Stringify floats to support NaN and Infinity
                    .float,
                    .double,
                    => .{ "/{s}", []const u8 },
                    .string,
                    .str_enum,
                    .trt_enum,
                    .timestamp_date_time,
                    .timestamp_http_date,
                    .timestamp_epoch_seconds,
                    => .{ "/{}", srlz.UriEncoder(is_greedy) },
                    .byte => .{ "/{d}", i8 },
                    .short => .{ "/{d}", i16 },
                    .integer, .int_enum => .{ "/{d}", i32 },
                    .long => .{ "/{d}", i64 },
                    inline .big_integer, .big_decimal => |g| @compileError("Unimplemted label type " ++ @tagName(g)),
                    else => unreachable,
                };

                @memcpy(fmt_str[fmt_len..][0..fmt_part.len], fmt_part);
                fmt_len += fmt_part.len;

                args_indices[args_len] = i;
                args_fields[args_len] = .{
                    .name = fmt.comptimePrint("{d}", .{args_len}),
                    .type = arg_typ,
                    .is_comptime = false,
                    .default_value = null,
                    .alignment = @alignOf(arg_typ),
                };
                args_len += 1;
            }
        }

        const fmt_dupe: [fmt_len]u8 = fmt_str[0..fmt_len].*;
        const idx_dupe: [args_len]usize = args_indices[0..args_len].*;
        const args_type = @Type(std.builtin.Type{ .@"struct" = .{
            .layout = .auto,
            .is_tuple = true,
            .fields = args_fields[0..args_len],
            .decls = &.{},
        } });
        break :blk .{ &fmt_dupe, args_type, idx_dupe };
    };

    var fmt_args: Args = undefined;
    inline for (0..fmt_args.len) |i| {
        const idx = args_indices[i];
        const member = members[idx];
        const scheme = member[3];
        const value = @field(input, member[1]);

        fmt_args[i] = switch (@as(smithy.SerialType, scheme[0])) {
            .int_enum => @intFromEnum(value),
            .byte, .short, .integer, .long => value,
            .boolean, .float, .double => try stringifyValue(allocator, scheme, value),
            .string,
            .str_enum,
            .trt_enum,
            .timestamp_date_time,
            .timestamp_http_date,
            .timestamp_epoch_seconds,
            => .{ .raw = try stringifyValue(allocator, scheme, value) },
            inline .big_integer, .big_decimal => |g| @compileError("Unimplemted label type " ++ @tagName(g)),
            else => unreachable,
        };
    }

    return fmt.allocPrint(allocator, fmt_str, fmt_args);
}

pub fn writeMetaParams(
    allocator: Allocator,
    comptime params: anytype,
    comptime members: anytype,
    input: anytype,
    request: *Request,
) !void {
    inline for (params) |meta| {
        const member = members[meta[1]];
        const required: bool = member[2];
        const scheme = member[3];
        const value = @field(input, member[1]);

        switch (@as(smithy.MetaParam, meta[0])) {
            .header_shape, .header_base64 => |k| {
                if (!required and value == null) continue;

                const key: []const u8 = meta[2];
                switch (@as(smithy.SerialType, scheme[0])) {
                    inline .list_dense, .list_sparse => |g| {
                        const item_scheme = scheme[2];
                        var values = std.ArrayList([]const u8).init(allocator);
                        for (value) |val| {
                            if (g == .list_sparse and val == null) continue;
                            try values.append(try stringifyValue(allocator, item_scheme, val));
                        }
                        try request.putHeaderMany(allocator, key, try values.toOwnedSlice());
                    },
                    .set => {
                        const item_scheme = scheme[2];
                        var it = value.iterator();
                        var values = std.ArrayList([]const u8).init(allocator);
                        while (it.next()) |val| {
                            try values.append(try stringifyValue(allocator, item_scheme, val));
                        }
                        try request.putHeaderMany(allocator, key, values.toOwnedSlice());
                    },
                    .string => {
                        const str = switch (k) {
                            .header_shape => try stringifyValue(allocator, scheme, value),
                            .header_base64 => try stringifyToBase64(allocator, value),
                            else => unreachable,
                        };
                        try request.putHeader(allocator, key, str);
                    },
                    else => {
                        const str = try stringifyValue(allocator, scheme, value);
                        try request.putHeader(allocator, key, str);
                    },
                }
            },
            .query_shape => {
                if (!required and value == null) continue;

                const key: []const u8 = meta[2];
                switch (@as(smithy.SerialType, scheme[0])) {
                    inline .list_dense, .list_sparse => |g| {
                        const item_scheme = scheme[2];
                        var values = std.ArrayList([]const u8).init(allocator);
                        for (value) |val| {
                            if (g == .list_sparse and val == null) continue;
                            try values.append(try stringifyValue(allocator, item_scheme, val));
                        }
                        try request.putQueryMany(allocator, key, try values.toOwnedSlice());
                    },
                    .set => {
                        const item_scheme = scheme[2];
                        var it = value.iterator();
                        var values = std.ArrayList([]const u8).init(allocator);
                        while (it.next()) |val| {
                            try values.append(try stringifyValue(allocator, item_scheme, val));
                        }
                        try request.putQueryMany(allocator, key, values.toOwnedSlice());
                    },
                    else => {
                        const str = try stringifyValue(allocator, scheme, value);
                        try request.putQuery(allocator, key, str);
                    },
                }
            },
            .header_map => {
                const prefix: []const u8 = meta[2];
                const item_type: smithy.SerialType = scheme[0];
                if (!required and value == null) continue;

                var it = value.iterator();
                while (it.next()) |entry| {
                    const key = try fmt.allocPrint(allocator, "{s}{s}", .{ prefix, entry.key_ptr.* });
                    try request.putHeader(allocator, key, switch (item_type) {
                        .string, .str_enum, .trt_enum => {
                            const str = try stringifyValue(allocator, scheme, entry.value_ptr.*);
                            try request.putQuery(allocator, key, str);
                        },
                        else => unreachable,
                    });
                }
            },
            .query_map => {
                const sparse_map: bool = scheme[1];
                if (!required and value == null) continue;

                var it = value.iterator();
                while (it.next()) |entry| {
                    const key = entry.key_ptr.*;
                    if (request.hasQuery(key)) continue;
                    if (sparse_map and entry.value_ptr.* == null) continue;

                    switch (@as(smithy.SerialType, scheme[0])) {
                        .string, .str_enum, .trt_enum => {
                            const str = try stringifyValue(allocator, scheme, value);
                            try request.putQuery(allocator, key, str);
                        },
                        .list_dense => {
                            const items = entry.value_ptr.*;
                            const list_item = scheme[2][0];
                            const str_vals = if (list_item == .string) items else blk: {
                                var list = std.ArrayList([]const u8).init(allocator);
                                for (items) |t| try list.append(t.toString());
                                break :blk try list.toOwnedSlice();
                            };
                            try request.putQueryMany(allocator, key, str_vals);
                        },
                        .list_sparse => {
                            const items = entry.value_ptr.*;
                            const list_item = scheme[2][0];
                            var str_vals = std.ArrayList([]const u8).init(allocator);
                            for (items) |t| {
                                if (t == null) continue;
                                try str_vals.append(if (list_item == .string) t else t.toString());
                            }
                            try request.putQueryMany(allocator, key, try str_vals.toOwnedSlice());
                        },
                        .set => {
                            const list_item = scheme[2][0];
                            var str_vals = std.ArrayList([]const u8).init(allocator);
                            var set_it = entry.value_ptr.iterator();
                            while (set_it.next()) |s| {
                                try str_vals.append(if (list_item == .string) s else s.toString());
                            }
                            try request.putQueryMany(allocator, key, str_vals.toOwnedSlice());
                        },
                        else => unreachable,
                    }
                }
            },
        }
    }
}

pub fn parseMeta(
    allocator: Allocator,
    comptime scheme: anytype,
    comptime members: anytype,
    response: Response,
    value: anytype,
) !void {
    if (@hasField(@TypeOf(scheme), "transport")) {
        const meta = scheme.transport;
        const member = members[meta[1]];
        const member_scheme = member[3];

        switch (@as(smithy.MetaTransport, meta[0])) {
            .status_code => {
                const int = @intFromEnum(response.status);
                @field(value, member[1]) = switch (@as(smithy.SerialType, member_scheme[0])) {
                    .byte, .short, .integer, .long => @intCast(int),
                    .int_enum => @enumFromInt(int),
                };
            },
        }
    }

    if (@hasField(@TypeOf(scheme), "params")) {
        var it = response.headersIterator();
        headers: while (it.next()) |header| inline for (scheme.params) |meta| {
            const member = members[meta[1]];
            const target = member[3];
            switch (@as(smithy.MetaParam, meta[0])) {
                .header_shape, .header_base64 => |k| {
                    const name: []const u8 = meta[2];
                    if (mem.eql(u8, name, header.name)) {
                        const target_value = &@field(value, member[1]);
                        switch (@as(smithy.SerialType, target[0])) {
                            .list_dense, .list_sparse => {
                                const Child = UnwrapListType(target_value);
                                const count = mem.count(u8, header.value, ",") + 1;
                                const list = try allocator.alloc(Child, count);
                                target_value.* = list;

                                var i: usize = 0;
                                var val_it = mem.splitScalar(u8, header.value, ',');
                                while (val_it.next()) |val| : (i += 1) {
                                    try parseStringValue(allocator, target[1], val, &list[i]);
                                }
                            },
                            .set => {
                                const Set = UnwrapType(target_value);
                                value.* = Set{};

                                var val_it = mem.splitScalar(u8, header.value, ',');
                                while (val_it.next()) |val| {
                                    var item: Set.Item = undefined;
                                    try parseStringValue(allocator, target[1], val, &item);
                                    try value.internal.putNoClobber(allocator, item, {});
                                }
                            },
                            .string => switch (k) {
                                .header_shape => try parseStringValue(allocator, target, header.value, target_value),
                                .header_base64 => target_value.* = try sliceFromBase64(allocator, header.value),
                            },
                            else => try parseStringValue(allocator, target, header.value, target_value),
                        }
                        continue :headers;
                    }
                },
                .header_map => {
                    const prefix: []const u8 = meta[2];
                    if (mem.startsWith(u8, header.name, prefix)) {
                        const fields = target[1];
                        const name = header.name[prefix.len..header.name.len];

                        switch (srlz.findMemberIndex(fields, name)) {
                            inline 0...(fields.len - 1) => |i| {
                                const field = fields[i];
                                const target_value = &@field(@field(value, member[1]), field[1]);
                                try parseStringValue(allocator, field[3], header.value, target_value);
                                continue :headers;
                            },
                            else => unreachable,
                        }

                        log.err("Unexpected response header: `{s}`", .{header.name});
                        return error.UnexpectedResponseHeader;
                    }
                },
            }
        };
    }
}

fn stringifyToBase64(arena: Allocator, value: []const u8) ![]const u8 {
    const size = std.base64.standard.Encoder.calcSize(value);
    const buffer = try arena.alloc(u8, size);
    try std.base64.standard.Encoder.encode(buffer, value);
    return buffer;
}

fn sliceFromBase64(arena: Allocator, value: []const u8) ![]const u8 {
    const size = try std.base64.standard.Decoder.calcSizeForSlice(value);
    const target = try arena.alloc(u8, size);
    try std.base64.standard.Decoder.decode(target, value);
    return target;
}

fn stringifyValue(arena: Allocator, comptime scheme: anytype, value: anytype) ![]const u8 {
    switch (@as(srlz.SerialType, scheme[0])) {
        .string => return value,
        .boolean => return if (value) "true" else "false",
        .str_enum, .trt_enum => return value.toString(),
        .int_enum => {
            const int: i32 = @intFromEnum(value);
            return fmt.allocPrint(arena, "{d}", .{int});
        },
        .byte, .short, .integer, .long => return fmt.allocPrint(arena, "{d}", .{value}),
        inline .float, .double => |g| {
            const T = if (g == .double) f64 else f32;
            if (std.math.isNan(value)) {
                return "NaN";
            } else if (std.math.inf(T) == value) {
                return "Infinity";
            } else if (-std.math.inf(T) == value) {
                return "-Infinity";
            } else {
                return fmt.allocPrint(arena, "{d}", .{value});
            }
        },
        .timestamp_epoch_seconds => {
            const float = value.asSecFloat();
            return fmt.allocPrint(arena, "{d}", .{float});
        },
        .timestamp_date_time => {
            var string = std.ArrayList(u8).init(arena);
            try srlz.writeTimestamp(string.writer().any(), value.epoch_ms);
            return string.toOwnedSlice();
        },
        .timestamp_http_date => {
            var string = std.ArrayList(u8).init(arena);
            try srlz.writeHttpDate(string.writer().any(), value.epoch_ms);
            return string.toOwnedSlice();
        },
        inline .big_integer, .big_decimal => |g| @compileError("Unimplemted serialization for type " ++ @tagName(g)),
        else => unreachable,
    }
}

fn parseStringValue(allocator: Allocator, comptime scheme: anytype, value: []const u8, target_ptr: anytype) !void {
    switch (@as(srlz.SerialType, scheme[0])) {
        .string => target_ptr.* = try allocator.dupe(u8, value),
        .boolean => target_ptr.* = mem.eql(u8, "true", value),
        .str_enum, .trt_enum => {
            const T = UnwrapType(target_ptr);
            target_ptr.* = T.parse(value);
            if (target_ptr.* == .UNKNOWN) {
                const dupe = try allocator.dupe(u8, value);
                target_ptr.* = .{ .UNKNOWN = dupe };
            }
        },
        .int_enum => {
            const int = try fmt.parseInt(i32, value, 10);
            target_ptr.* = @enumFromInt(int);
        },
        .byte => target_ptr.* = try fmt.parseInt(i8, value, 10),
        .short => target_ptr.* = try fmt.parseInt(i16, value, 10),
        .integer => target_ptr.* = try fmt.parseInt(i32, value, 10),
        .long => target_ptr.* = try fmt.parseInt(i64, value, 10),
        inline .float, .double => |g| {
            const F = if (g == .double) f64 else f32;
            target_ptr.* = try fmt.parseFloat(F, value);
        },
        .timestamp_date_time => {
            const epoch_ms = try srlz.parseTimestamp(value);
            target_ptr.* = .{ .epoch_ms = epoch_ms };
        },
        .timestamp_http_date => {
            const epoch_ms = try srlz.parseHttpDate(value);
            target_ptr.* = .{ .epoch_ms = epoch_ms };
        },
        .timestamp_epoch_seconds => {
            if (mem.indexOfScalar(u8, value, '.') != null) {
                const dbl = try fmt.parseFloat(f64, value);
                const epoch_ms: i64 = @intFromFloat(dbl * std.time.ms_per_s);
                target_ptr.* = .{ .epoch_ms = epoch_ms };
            } else {
                const int = try fmt.parseInt(i64, value, 10);
                const epoch_ms = int * std.time.ms_per_s;
                target_ptr.* = .{ .epoch_ms = epoch_ms };
            }
        },
        inline .big_integer, .big_decimal => |g| @compileError("Unimplemted serialization for type " ++ @tagName(g)),
        else => unreachable,
    }
}

fn UnwrapType(target_ptr: anytype) type {
    return switch (@typeInfo(@TypeOf(target_ptr.*))) {
        .optional => |m| m.child,
        else => @TypeOf(target_ptr.*),
    };
}

fn UnwrapListType(target_ptr: anytype) type {
    return switch (@typeInfo(@TypeOf(target_ptr.*))) {
        .pointer => |m| m.child,
        .optional => |m| @typeInfo(m.child).pointer.child,
        else => unreachable,
    };
}
