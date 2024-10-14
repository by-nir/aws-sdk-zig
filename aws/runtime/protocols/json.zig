//! - https://smithy.io/2.0/aws/protocols/aws-json-1_0-protocol.html
//! - https://smithy.io/2.0/aws/protocols/aws-json-1_1-protocol.html
//! - https://smithy.io/2.0/aws/protocols/aws-restjson1-protocol.html
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const testing = std.testing;
const smithy = @import("smithy/runtime");
const srlz = smithy.serial;
const Request = @import("../http.zig").Request;
const Response = @import("../http.zig").Response;

const log = std.log.scoped(.aws_sdk);
const JsonWriter = std.json.WriteStream(std.ArrayList(u8).Writer, .{ .checked_to_fixed_depth = 256 });
const JsonReader = std.json.Reader(std.json.default_buffer_size, std.io.FixedBufferStream([]const u8).Reader);

pub fn requestPayload(
    allocator: Allocator,
    comptime meta: anytype,
    comptime member: anytype,
    request: *Request,
    value: anytype,
) !void {
    switch (@as(smithy.MetaPayload, meta[0])) {
        .media => {
            request.payload = value;
            try request.putHeader(allocator, "content-type", meta[2]);
        },
        .shape => {
            const scheme = member[3];
            const required: bool = member[2];
            const shape: smithy.SerialType = scheme[0];

            try request.putHeader(allocator, "content-type", switch (shape) {
                .blob => "application/octet-stream",
                .str_enum, .trt_enum, .string => "text/plain",
                .document, .structure, .tagged_union => "application/json",
                else => unreachable,
            });

            switch (shape) {
                .string, .blob => request.payload = value,
                .str_enum, .trt_enum => request.payload = value.toString(),
                .document, .structure, .tagged_union => {
                    if (!required and value == null) return;
                    var payload = std.ArrayList(u8).init(allocator);
                    var json = std.json.writeStream(payload.writer(), .{});
                    try writeValue(&json, scheme, value);
                    request.payload = try payload.toOwnedSlice();
                },
                else => unreachable,
            }
        },
    }
}

pub fn requestShape(
    allocator: Allocator,
    comptime members: anytype,
    comptime body_ids: anytype,
    content_type: []const u8,
    request: *Request,
    input: anytype,
) !void {
    try request.putHeader(allocator, "content-type", content_type);

    var payload = std.ArrayList(u8).init(allocator);
    var json = std.json.writeStream(payload.writer(), .{});
    try json.beginObject();
    inline for (body_ids) |i| {
        try writeStructMember(&json, members[i], input);
    }
    try json.endObject();
    request.payload = try payload.toOwnedSlice();
}

fn writeValue(json: *JsonWriter, comptime scheme: anytype, value: anytype) !void {
    switch (@as(smithy.SerialType, scheme[0])) {
        .boolean, .byte, .short, .integer, .long, .string => try json.write(value),
        inline .float, .double => |g| {
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
        inline .list_dense, .list_sparse => |g| {
            const member_scheme = scheme[1];
            try json.beginArray();
            for (value) |item| {
                if (g == .list_sparse and item == null) {
                    try json.write(null);
                } else {
                    try writeValue(json, member_scheme, item);
                }
            }
            try json.endArray();
        },
        .set => {
            const member_scheme = scheme[1];
            try json.beginArray();
            var it = value.iterator();
            while (it.next()) |item| {
                try writeValue(json, member_scheme, item);
            }
            try json.endArray();
        },
        .map => {
            const sparse: bool = scheme[1];
            // const key_scheme = scheme[2];
            const val_scheme = scheme[3];
            try json.beginObject();
            var it = value.iterator();
            while (it.next()) |entry| {
                try json.objectField(entry.key_ptr.*);
                if (sparse and entry.value_ptr.* == null) {
                    try json.write(null);
                } else {
                    try writeValue(json, val_scheme, entry.value_ptr);
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
                            if (mem.eql(u8, member_name, @tagName(g))) break :blk members[i];
                        }
                        unreachable;
                    };

                    try json.objectField(member_scheme[0]);
                    try writeValue(json, member_scheme[2], v);
                },
            }
            try json.endObject();
        },
        .structure => {
            const members = scheme[1];
            try json.beginObject();
            inline for (members) |member| {
                try writeStructMember(json, member, value);
            }
            try json.endObject();
        },
        .timestamp_epoch_seconds => try json.write(value.asSecFloat()),
        .timestamp_date_time => {
            try json.beginWriteRaw();
            try json.stream.writeByte('\"');
            try srlz.writeTimestamp(json.stream.any(), value.epoch_ms);
            try json.stream.writeByte('\"');
            json.endWriteRaw();
        },
        .timestamp_http_date => {
            try json.beginWriteRaw();
            try json.stream.writeByte('\"');
            try srlz.writeHttpDate(json.stream.any(), value.epoch_ms);
            try json.stream.writeByte('\"');
            json.endWriteRaw();
        },
        inline else => |g| {
            // document, big_integer, big_decimal
            @compileError("Unimplemted serialization for type " ++ @tagName(g));
        },
    }
}

fn writeStructMember(json: *JsonWriter, comptime scheme: anytype, struct_value: anytype) !void {
    const api_name: []const u8 = scheme[0];
    const field_name: []const u8 = scheme[1];
    const required: bool = scheme[2];
    const member_scheme = scheme[3];

    const has_value: bool, const member_value = if (required)
        .{ true, @field(struct_value, field_name) }
    else if (@field(struct_value, field_name)) |val|
        .{ true, val }
    else
        .{ false, null };

    if (has_value) {
        try json.objectField(api_name);
        try writeValue(json, member_scheme, member_value);
    }
}

pub fn responseOutput(
    scratch_alloc: Allocator,
    output_alloc: Allocator,
    comptime scheme: anytype,
    payload: []const u8,
    value: anytype,
) !void {
    if (@hasField(@TypeOf(scheme[0]), "payload")) {
        const meta = scheme[0].payload;
        const member = scheme[2][meta[1]];
        try responsePayload(scratch_alloc, output_alloc, member, meta[0], payload, value);
    } else if (scheme[1].len > 0) {
        try responseShape(scratch_alloc, output_alloc, scheme[2], payload, value);
    } else {
        std.debug.assert(payload.len == 0);
    }
}

fn responsePayload(
    scratch_alloc: Allocator,
    output_alloc: Allocator,
    comptime member: anytype,
    comptime kind: smithy.MetaPayload,
    payload: []const u8,
    value: anytype,
) !void {
    switch (@as(smithy.MetaPayload, kind)) {
        .media => value.* = payload,
        .shape => {
            const required: bool = member[2];
            const scheme = member[3];
            switch (@as(smithy.SerialType, scheme[0])) {
                .string, .blob => value.* = payload,
                .str_enum, .trt_enum, .document, .structure, .tagged_union => {
                    var stream = std.io.fixedBufferStream(payload);
                    var reader = std.json.reader(scratch_alloc, stream.reader());
                    if (!required and .null == try reader.peekNextTokenType()) return;
                    try parseStructMemberValue(scratch_alloc, output_alloc, &reader, scheme, value);
                },
                else => unreachable,
            }
        },
    }
}

fn responseShape(
    scratch_alloc: Allocator,
    output_alloc: Allocator,
    comptime members: anytype,
    payload: []const u8,
    value: anytype,
) !void {
    var stream = std.io.fixedBufferStream(payload);
    var reader = std.json.reader(scratch_alloc, stream.reader());

    if ((try reader.next()) != .object_begin) return error.UnexpectedToken;
    while (try reader.peekNextTokenType() != .object_end) {
        switch (try parseMemberIndex(scratch_alloc, &reader, members)) {
            inline 0...(members.len - 1) => |i| {
                const member = members[i];
                try parseStructMemberValue(scratch_alloc, output_alloc, &reader, member, value);
            },
            else => unreachable,
        }
    }
    if ((try reader.next()) != .object_end) return error.UnexpectedToken;
}

fn parseValue(
    scratch_alloc: Allocator,
    output_alloc: Allocator,
    json: *JsonReader,
    comptime scheme: anytype,
    value: anytype,
) !void {
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
            const member_value = try output_alloc.alloc(u8, size);
            try std.base64.standard.Decoder.decode(member_value, str_value);
            value.* = member_value;
        },
        inline .list_dense, .list_sparse => |g| {
            const member_scheme = scheme[1];

            const Child = switch (@typeInfo(@TypeOf(value.*))) {
                .pointer => |m| m.child,
                .optional => |m| @typeInfo(m.child).pointer.child,
                else => unreachable,
            };

            var list = std.ArrayList(Child).init(output_alloc);

            if ((try json.next()) != .array_begin) return error.UnexpectedToken;
            while (try json.peekNextTokenType() != .array_end) {
                if (g == .list_sparse and .null == try json.peekNextTokenType()) {
                    try list.append(null);
                } else {
                    try parseValue(scratch_alloc, output_alloc, json, member_scheme, try list.addOne());
                }
            }
            if ((try json.next()) != .array_end) return error.UnexpectedToken;

            value.* = try list.toOwnedSlice();
        },
        .set => {
            const member_scheme = scheme[1];

            const Set = ValueType(value);
            var set = Set{};

            if ((try json.next()) != .array_begin) return error.UnexpectedToken;
            while (try json.peekNextTokenType() != .array_end) {
                var item: Set.Item = undefined;
                try parseValue(scratch_alloc, output_alloc, json, member_scheme, &item);
                try set.internal.putNoClobber(output_alloc, item, {});
            }
            if ((try json.next()) != .array_end) return error.UnexpectedToken;

            value.* = set;
        },
        .map => {
            const sparse = scheme[1];
            // const key_scheme = scheme[2];
            const val_scheme = scheme[3];

            const HashMap = ValueType(value);
            const Item = std.meta.fieldInfo(HashMap.KV, .value).type;

            var map = HashMap{};

            if ((try json.next()) != .object_begin) return error.UnexpectedToken;
            while (try json.peekNextTokenType() != .object_end) {
                const key = try std.json.innerParse([]const u8, scratch_alloc, json, .{
                    .allocate = .alloc_if_needed,
                    .max_value_len = std.json.default_max_value_len,
                });

                if (sparse and .null == try json.peekNextTokenType()) {
                    try map.internal.putNoClobber(output_alloc, key, null);
                } else {
                    var item: Item = undefined;
                    try parseValue(scratch_alloc, output_alloc, json, val_scheme, &item);
                    try map.internal.putNoClobber(output_alloc, key, item);
                }
            }
            if ((try json.next()) != .object_end) return error.UnexpectedToken;

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

            if ((try json.next()) != .object_begin) return error.UnexpectedToken;
            switch (try parseMemberIndex(scratch_alloc, json, members)) {
                inline 0...(members.len - 1) => |i| {
                    const member = members[i];
                    const field_name = member[1];
                    const val_scheme = member[2];

                    var item: std.meta.TagPayloadByName(Union, field_name) = undefined;
                    try parseValue(scratch_alloc, output_alloc, json, val_scheme, &item);
                    value.* = @unionInit(Union, field_name, item);
                },
                else => unreachable,
            }
            if ((try json.next()) != .object_end) return error.UnexpectedToken;
        },
        .structure => {
            const members = scheme[1];
            if ((try json.next()) != .object_begin) return error.UnexpectedToken;
            while (try json.peekNextTokenType() != .object_end) {
                switch (try parseMemberIndex(scratch_alloc, json, members)) {
                    inline 0...(members.len - 1) => |i| {
                        const member = members[i];
                        try parseStructMemberValue(scratch_alloc, output_alloc, json, member, value);
                    },
                    else => unreachable,
                }
            }
            if ((try json.next()) != .object_end) return error.UnexpectedToken;
        },
        .timestamp_date_time => {
            const str_value = try std.json.innerParse([]const u8, scratch_alloc, json, .{
                .allocate = .alloc_if_needed,
                .max_value_len = std.json.default_max_value_len,
            });
            const epoch_ms = try srlz.parseTimestamp(str_value);
            value.* = .{ .epoch_ms = epoch_ms };
        },
        .timestamp_http_date => {
            const str_value = try std.json.innerParse([]const u8, scratch_alloc, json, .{
                .allocate = .alloc_if_needed,
                .max_value_len = std.json.default_max_value_len,
            });
            const epoch_ms = try srlz.parseHttpDate(str_value);
            value.* = .{ .epoch_ms = epoch_ms };
        },
        .timestamp_epoch_seconds => {
            switch (try json.nextAlloc(scratch_alloc, .alloc_if_needed)) {
                .number, .allocated_number => |s| {
                    if (mem.indexOfScalar(u8, s, '.') != null) {
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

fn parseMemberIndex(arena: Allocator, json: *JsonReader, comptime members: anytype) !usize {
    const key_name = try std.json.innerParse([]const u8, arena, json, .{
        .allocate = .alloc_if_needed,
        .max_value_len = std.json.default_max_value_len,
    });

    if (srlz.findMemberIndex(members, key_name)) |i| {
        return i;
    } else {
        log.err("Unexpected response member: `{s}`", .{key_name});
        return error.UnexpectedResponseMember;
    }
}

fn parseStructMemberValue(
    scratch_alloc: Allocator,
    output_alloc: Allocator,
    json: *JsonReader,
    comptime member: anytype,
    struct_value: anytype,
) !void {
    const field_name: []const u8 = member[1];
    const required: bool = member[2];
    const scheme = member[3];

    if (!required and .null == try json.peekNextTokenType()) {
        @field(struct_value, field_name) = null;
    } else {
        const value = &@field(struct_value, field_name);
        try parseValue(scratch_alloc, output_alloc, json, scheme, value);
    }
}

fn ValueType(value: anytype) type {
    return switch (@typeInfo(@TypeOf(value.*))) {
        .optional => |m| m.child,
        else => @TypeOf(value.*),
    };
}

pub fn responseError(
    scratch_alloc: Allocator,
    output_arena: *ArenaAllocator,
    comptime scheme: anytype,
    comptime E: type,
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
                if (mem.eql(u8, "code", param)) {
                    const val = try json.next();
                    if (val == .string) code = val.string;
                    continue :loop;
                } else if (code == null and mem.eql(u8, "__type", param)) {
                    const val = try json.next();
                    if (val == .string) code = val.string;
                    continue :loop;
                } else inline for (.{ "message", "Message", "errorMessage" }) |expected| {
                    if (msg == null and mem.eql(u8, expected, param)) {
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
    if (mem.indexOfScalar(u8, code, ':')) |i| code = code[0..i];
    if (mem.indexOfScalar(u8, code, '#')) |i| code = code[i + 1 .. code.len];
    return if (code.len > 0) code else null;
}

test sanitizeErrorCode {
    try testing.expectEqual(null, sanitizeErrorCode("foo#:bar"));
    try testing.expectEqualStrings("FooError", sanitizeErrorCode("FooError").?);
    try testing.expectEqualStrings("FooError", sanitizeErrorCode("aws.protocoltests.restjson#FooError").?);
    try testing.expectEqualStrings("FooError", sanitizeErrorCode("FooError:http://internal.amazon.com/coral/com.amazon.coral.validate/").?);
    try testing.expectEqualStrings("FooError", sanitizeErrorCode("aws.protocoltests.restjson#FooError:http://internal.amazon.com/coral/com.amazon.coral.validate/").?);
}
