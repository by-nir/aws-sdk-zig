//! - https://smithy.io/2.0/aws/protocols/aws-json-1_0-protocol.html
//! - https://smithy.io/2.0/aws/protocols/aws-json-1_1-protocol.html
//! - https://smithy.io/2.0/aws/protocols/aws-restjson1-protocol.html
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const smithy = @import("smithy/runtime");
const Response = @import("../http.zig").Response;
const Operation = @import("../http.zig").Operation;

const log = std.log.scoped(.aws_sdk);
const JsonWriter = std.json.WriteStream(std.ArrayList(u8).Writer, .{ .checked_to_fixed_depth = 256 });
const JsonReader = std.json.Reader(std.json.default_buffer_size, std.io.FixedBufferStream([]const u8).Reader);

pub const JsonFlavor = enum {
    aws_1_0,
    aws_1_1,
};

/// Caller owns the returned memory.
pub fn operationRequest(
    comptime flavor: JsonFlavor,
    comptime target: []const u8,
    comptime scheme: anytype,
    op: *Operation,
    input: anytype,
) !void {
    const req = &op.request;
    try req.headers.put(op.allocator, "x-amz-target", target);
    try req.headers.put(op.allocator, "content-type", switch (flavor) {
        .aws_1_0 => "application/x-amz-json-1.0",
        .aws_1_1 => "application/x-amz-json-1.1",
    });

    var payload = std.ArrayList(u8).init(op.allocator);
    errdefer payload.deinit();

    var json = std.json.writeStream(payload.writer(), .{});
    try serializeValue(&json, scheme, input);
    req.payload = try payload.toOwnedSlice();
}

fn serializeValue(json: *JsonWriter, comptime scheme: anytype, value: anytype) !void {
    switch (@as(smithy.SerialType, scheme[0])) {
        .boolean, .byte, .short, .integer, .long, .string => try json.write(value),
        inline .float, .double => |_, g| {
            const T = if (g == .double) f64 else f32;
            if (std.math.isNan(value)) {
                try json.write("NaN");
            } else if (std.math.inf(T) == value) {
                try json.write("Infinity");
            } else if (-std.math.inf(T) == value) {
                try json.write("-Infinity");
            } else {
                try json.write(value);
            }
        },
        .blob => {
            try json.beginWriteRaw();
            try json.stream.writeByte('\"');
            try std.base64.standard.Encoder.encodeWriter(json.stream, value);
            try json.stream.writeByte('\"');
            try json.endWriteRaw();
        },
        .list => {
            const required = scheme[1];
            const member_scheme = scheme[2];
            try json.beginArray();
            for (value) |item| {
                if (!required and item == null) {
                    try json.write(null);
                } else {
                    try serializeValue(json, member_scheme, item);
                }
            }
            try json.endArray();
        },
        .set => {
            const member_scheme = scheme[1];
            try json.beginArray();
            var it = value.iterator();
            while (it.next()) |item| {
                try serializeValue(json, member_scheme, item);
            }
            try json.endArray();
        },
        .map => {
            const required = scheme[1];
            // const key_scheme = scheme[2];
            const val_scheme = scheme[3];
            try json.beginObject();
            var it = value.iterator();
            while (it.next()) |entry| {
                try json.objectField(entry.key_ptr);
                if (!required and entry.value_ptr == null) {
                    try json.write(null);
                } else {
                    try serializeValue(json, val_scheme, entry.value_ptr);
                }
            }
            try json.endObject();
        },
        .int_enum => try json.write(@as(i32, @intFromEnum(value))),
        .str_enum, .trt_enum => try json.write(value.toString()),
        .tagged_union => {
            const members = scheme[1];
            try json.beginObject();
            switch (value) {
                inline else => |v, g| {
                    const member_scheme = comptime blk: {
                        for (members, 0..) |member, i| {
                            const member_name = member[1];
                            if (std.mem.eql(u8, member_name, @tagName(g))) break :blk members[i];
                        }
                        unreachable;
                    };

                    try json.objectField(member_scheme[0]);
                    try serializeValue(json, member_scheme[2], v);
                },
            }
            try json.endObject();
        },
        .structure => {
            const members = scheme[1];
            try json.beginObject();
            inline for (members) |member| {
                const name_spec: []const u8 = member[0];
                const name_field: []const u8 = member[1];
                const required: bool = member[2];
                const member_scheme = member[3];

                const has_value: bool, const member_value = if (required)
                    .{ true, @field(value, name_field) }
                else if (@field(value, name_field)) |val|
                    .{ true, val }
                else
                    .{ false, null };

                if (has_value) {
                    try json.objectField(name_spec);
                    try serializeValue(json, member_scheme, member_value);
                }
            }
            try json.endObject();
        },
        .timestamp_epoch_seconds => try json.write(value.asSecFloat()),
        .timestamp_date_time => {
            try json.beginWriteRaw();
            try json.stream.writeByte('\"');
            try smithy.serial.writeTimestamp(json.stream.any(), value.epoch_ms);
            try json.stream.writeByte('\"');
            json.endWriteRaw();
        },
        .timestamp_http_date => {
            try json.beginWriteRaw();
            try json.stream.writeByte('\"');
            try smithy.serial.writeHttpDate(json.stream.any(), value.epoch_ms);
            try json.stream.writeByte('\"');
            json.endWriteRaw();
        },
        inline else => |g| {
            // document, big_integer, big_decimal
            @compileError("Unimplemted serialization for type " ++ @tagName(g));
        },
    }
}

pub fn operationResponse(
    comptime flavor: JsonFlavor,
    comptime Out: type,
    comptime out_scheme: anytype,
    comptime Err: type,
    comptime err_scheme: anytype,
    output_arena: *std.heap.ArenaAllocator,
    op: *Operation,
) !smithy.Result(Out, Err) {
    const rsp = op.response orelse return error.MissingResponse;
    return switch (rsp.status.class()) {
        .success => .{ .ok = try handleOutput(flavor, Out, out_scheme, op.allocator, output_arena, rsp) },
        .client_error,
        .server_error,
        => .{ .fail = try handleError(flavor, Err, err_scheme, op.allocator, output_arena, rsp) },
        else => error.UnexpectedResponseStatus,
    };
}

fn handleOutput(
    comptime _: JsonFlavor,
    comptime T: type,
    comptime scheme: anytype,
    scratch_alloc: Allocator,
    output_arena: *std.heap.ArenaAllocator,
    response: Response,
) !T {
    if (response.body.len == 0) return .{};

    var stream = std.io.fixedBufferStream(response.body);
    var reader = std.json.reader(scratch_alloc, stream.reader());
    defer reader.deinit();

    var value: T = .{};
    try parseValue(scratch_alloc, output_arena.allocator(), &reader, scheme, &value);
    if (output_arena.queryCapacity() > 0) value.arena = output_arena.*;
    return value;
}

fn handleError(
    comptime _: JsonFlavor,
    comptime E: type,
    comptime scheme: anytype,
    scratch_alloc: Allocator,
    output_arena: *std.heap.ArenaAllocator,
    response: Response,
) !smithy.ResultError(E) {
    var stream = std.io.fixedBufferStream(response.body);
    var reader = std.json.reader(scratch_alloc, stream.reader());

    const body_code, const body_msg = try parseBodyError(&reader);
    const header_code = parseHeaderError(response);

    var code = header_code orelse body_code orelse return error.UnresolvedResponseError;
    code = sanitizeErrorCode(code) orelse return error.UnresolvedResponseError;

    const map = comptime blk: {
        const members = scheme[1];
        var entries: [members.len]struct { []const u8, E } = undefined;
        for (members, 0..) |entry, i| {
            entries[i] = .{ entry[0], std.enums.nameCast(E, entry[1]) };
        }
        break :blk std.StaticStringMap(E).initComptime(entries);
    };
    const resolved: E = map.get(code) orelse {
        log.err("Unresolved response error: `{s}`", .{code});
        return error.UnresolvedResponseError;
    };

    const msg = body_msg orelse return .{ .kind = resolved };
    const dupe = try output_arena.allocator().dupe(u8, msg);
    return .{
        .kind = resolved,
        .message = dupe,
        .arena = output_arena.*,
    };
}

fn parseBodyError(json: *JsonReader) !struct { ?[]const u8, ?[]const u8 } {
    if (try json.next() != .object_begin) return .{ null, null };

    var code: ?[]const u8 = null;
    var msg: ?[]const u8 = null;

    loop: while (true) {
        switch (try json.next()) {
            .object_end => break :loop,
            .string => |param| {
                if (std.mem.eql(u8, "code", param)) {
                    const val = try json.next();
                    if (val == .string) code = val.string;
                    continue :loop;
                } else if (code == null and std.mem.eql(u8, "__type", param)) {
                    const val = try json.next();
                    if (val == .string) code = val.string;
                    continue :loop;
                } else inline for (.{ "message", "Message", "errorMessage" }) |expected| {
                    if (msg == null and std.mem.eql(u8, expected, param)) {
                        const val = try json.next();
                        if (val == .string) msg = val.string;
                        continue :loop;
                    }
                }

                try json.skipValue();
            },
            else => break :loop,
        }
    }

    return .{ code, msg };
}

fn parseHeaderError(response: Response) ?[]const u8 {
    var headers = response.headersIterator();
    while (headers.next()) |header| {
        if (!std.ascii.startsWithIgnoreCase(header.name, "x-amzn-errortype")) continue;
        return header.value;
    }

    return null;
}

fn sanitizeErrorCode(raw: []const u8) ?[]const u8 {
    var code = raw;
    if (std.mem.indexOfScalar(u8, code, ':')) |i| code = code[0..i];
    if (std.mem.indexOfScalar(u8, code, '#')) |i| code = code[i + 1 .. code.len];
    return if (code.len > 0) code else null;
}

test sanitizeErrorCode {
    try testing.expectEqual(null, sanitizeErrorCode("foo#:bar"));
    try testing.expectEqualStrings("FooError", sanitizeErrorCode("FooError").?);
    try testing.expectEqualStrings("FooError", sanitizeErrorCode("aws.protocoltests.restjson#FooError").?);
    try testing.expectEqualStrings("FooError", sanitizeErrorCode("FooError:http://internal.amazon.com/coral/com.amazon.coral.validate/").?);
    try testing.expectEqualStrings("FooError", sanitizeErrorCode("aws.protocoltests.restjson#FooError:http://internal.amazon.com/coral/com.amazon.coral.validate/").?);
}

fn parseValue(scratch_alloc: Allocator, output_alloc: Allocator, json: *JsonReader, comptime scheme: anytype, value: anytype) !void {
    switch (@as(smithy.SerialType, scheme[0])) {
        .boolean => value.* = try std.json.innerParse(bool, scratch_alloc, json, .{}),
        .byte => value.* = try std.json.innerParse(i8, scratch_alloc, json, .{}),
        .short => value.* = try std.json.innerParse(i16, scratch_alloc, json, .{}),
        .integer => value.* = try std.json.innerParse(i32, scratch_alloc, json, .{}),
        .long => value.* = try std.json.innerParse(i64, scratch_alloc, json, .{}),
        .float => value.* = try std.json.innerParse(f32, scratch_alloc, json, .{}),
        .double => value.* = try std.json.innerParse(f64, scratch_alloc, json, .{}),
        .string => {
            value.* = try std.json.innerParse([]const u8, output_alloc, json, .{
                .allocate = .alloc_always,
                .max_value_len = std.json.default_max_value_len,
            });
        },
        .blob => {
            const str_value = try std.json.innerParse([]const u8, scratch_alloc, json, .{
                .allocate = .alloc_if_needed,
                .max_value_len = std.json.default_max_value_len,
            });
            const size = try std.base64.standard.Decoder.calcSizeForSlice(str_value);
            const target = try output_alloc.alloc(u8, size);
            try std.base64.standard.Decoder.decode(target, str_value);
            value.* = target;
        },
        .list => {
            const required = scheme[1];
            const member_scheme = scheme[2];

            const Child = switch (@typeInfo(@TypeOf(value.*))) {
                .pointer => |m| m.child,
                .optional => |m| @typeInfo(m.child).pointer.child,
                else => unreachable,
            };

            var list = std.ArrayList(Child).init(output_alloc);

            switch (try json.next()) {
                .array_begin => {},
                else => return error.UnexpectedToken,
            }

            while (try json.peekNextTokenType() != .array_end) {
                if (!required and .null == try json.peekNextTokenType()) {
                    try list.append(null);
                } else {
                    try parseValue(scratch_alloc, output_alloc, json, member_scheme, try list.addOne());
                }
            }

            switch (try json.next()) {
                .array_end => {},
                else => return error.UnexpectedToken,
            }

            value.* = try list.toOwnedSlice();
        },
        .set => {
            const member_scheme = scheme[1];

            const Set = ValueType(value);
            var set = Set{};

            switch (try json.next()) {
                .array_begin => {},
                else => return error.UnexpectedToken,
            }

            while (try json.peekNextTokenType() != .array_end) {
                var item: Set.Item = undefined;
                try parseValue(scratch_alloc, output_alloc, json, member_scheme, &item);
                try set.internal.putNoClobber(output_alloc, item, {});
            }

            switch (try json.next()) {
                .array_end => {},
                else => return error.UnexpectedToken,
            }

            value.* = set;
        },
        .map => {
            const required = scheme[1];
            // const key_scheme = scheme[2];
            const val_scheme = scheme[3];

            const HashMap = ValueType(value);
            const Item = std.meta.fieldInfo(HashMap.KV, .value).type;

            var map = HashMap{};

            switch (try json.next()) {
                .object_begin => {},
                else => return error.UnexpectedToken,
            }

            while (try json.peekNextTokenType() != .object_end) {
                const key = try std.json.innerParse([]const u8, scratch_alloc, json, .{
                    .allocate = .alloc_if_needed,
                    .max_value_len = std.json.default_max_value_len,
                });

                if (!required and .null == try json.peekNextTokenType()) {
                    try map.internal.putNoClobber(output_alloc, key, null);
                } else {
                    var item: Item = undefined;
                    try parseValue(scratch_alloc, output_alloc, json, val_scheme, &item);
                    try map.internal.putNoClobber(output_alloc, key, item);
                }
            }

            switch (try json.next()) {
                .object_end => {},
                else => return error.UnexpectedToken,
            }

            value.* = map;
        },
        .int_enum => {
            const Enum = ValueType(value);
            const Int = std.meta.Tag(Enum);
            const int_value = try std.json.innerParse(Int, scratch_alloc, json, .{
                .max_value_len = std.json.default_max_value_len,
            });
            value.* = @enumFromInt(int_value);
        },
        .str_enum, .trt_enum => {
            const str_value = try std.json.innerParse([]const u8, output_alloc, json, .{
                .allocate = .alloc_always,
                .max_value_len = std.json.default_max_value_len,
            });

            const T = ValueType(value);
            const resolved = T.parse(str_value);
            if (resolved != .UNKNOWN) output_alloc.free(str_value);

            value.* = resolved;
        },
        .tagged_union => {
            const members = scheme[1];
            const Union = ValueType(value);

            switch (try json.next()) {
                .object_begin => {},
                else => return error.UnexpectedToken,
            }

            const key = try std.json.innerParse([]const u8, scratch_alloc, json, .{
                .allocate = .alloc_if_needed,
                .max_value_len = std.json.default_max_value_len,
            });

            var found = false;
            inline for (members) |member| {
                const spec_name = member[0];
                const field_name = member[1];
                const val_scheme = member[2];

                if (std.mem.eql(u8, spec_name, key)) {
                    var item: std.meta.TagPayloadByName(Union, field_name) = undefined;
                    try parseValue(scratch_alloc, output_alloc, json, val_scheme, &item);
                    value.* = @unionInit(Union, field_name, item);
                    found = true;
                }
            }

            if (!found) {
                log.err("Unexpected response union field: `{s}`", .{key});
                return error.UnexpectedResponseUnionField;
            }

            switch (try json.next()) {
                .object_end => {},
                else => return error.UnexpectedToken,
            }
        },
        .structure => {
            const members = scheme[1];

            switch (try json.next()) {
                .object_begin => {},
                else => return error.UnexpectedToken,
            }

            obj: while (try json.peekNextTokenType() != .object_end) {
                const key = try std.json.innerParse([]const u8, scratch_alloc, json, .{
                    .allocate = .alloc_if_needed,
                    .max_value_len = std.json.default_max_value_len,
                });

                inline for (members) |member| {
                    const name_spec: []const u8 = member[0];
                    const name_field: []const u8 = member[1];
                    const required: bool = member[2];
                    const member_scheme = member[3];

                    if (std.mem.eql(u8, name_spec, key)) {
                        if (!required and .null == try json.peekNextTokenType()) {
                            @field(value, name_field) = null;
                        } else {
                            try parseValue(scratch_alloc, output_alloc, json, member_scheme, &@field(value, name_field));
                        }

                        continue :obj;
                    }
                }

                log.err("Unexpected response struct field: `{s}`", .{key});
                return error.UnexpectedResponseStructField;
            }

            switch (try json.next()) {
                .object_end => {},
                else => return error.UnexpectedToken,
            }
        },
        .timestamp_date_time => {
            const str_value = try std.json.innerParse([]const u8, scratch_alloc, json, .{
                .allocate = .alloc_if_needed,
                .max_value_len = std.json.default_max_value_len,
            });
            const epoch_ms = try smithy.serial.parseTimestamp(str_value);
            value.* = .{ .epoch_ms = epoch_ms };
        },
        .timestamp_http_date => {
            const str_value = try std.json.innerParse([]const u8, scratch_alloc, json, .{
                .allocate = .alloc_if_needed,
                .max_value_len = std.json.default_max_value_len,
            });
            const epoch_ms = try smithy.serial.parseHttpDate(str_value);
            value.* = .{ .epoch_ms = epoch_ms };
        },
        .timestamp_epoch_seconds => {
            switch (try json.nextAlloc(scratch_alloc, .alloc_if_needed)) {
                .number, .allocated_number => |s| {
                    if (std.mem.indexOfScalar(u8, s, '.') != null) {
                        const dbl = try std.fmt.parseFloat(f64, s);
                        const epoch_ms: i64 = @intFromFloat(dbl * std.time.ms_per_s);
                        value.* = .{ .epoch_ms = epoch_ms };
                    } else {
                        const int = try std.fmt.parseInt(i64, s, 10);
                        const epoch_ms = int * std.time.ms_per_s;
                        value.* = .{ .epoch_ms = epoch_ms };
                    }
                },
                else => unreachable,
            }
        },
        inline else => |g| {
            // document, big_integer, big_decimal
            @compileError("Unimplemted parsing for type " ++ @tagName(g));
        },
    }
}

fn ValueType(value: anytype) type {
    return switch (@typeInfo(@TypeOf(value.*))) {
        .optional => |m| m.child,
        else => @TypeOf(value.*),
    };
}
