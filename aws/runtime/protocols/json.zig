//! - https://smithy.io/2.0/aws/protocols/aws-json-1_0-protocol.html
//! - https://smithy.io/2.0/aws/protocols/aws-json-1_1-protocol.html
//! - https://smithy.io/2.0/aws/protocols/aws-restjson1-protocol.html
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const testing = std.testing;
const smithy = @import("smithy/runtime");
const srl = smithy.serial;
const http = @import("../http.zig");

const log = std.log.scoped(.aws_sdk);
const JsonWriter = std.json.WriteStream(std.ArrayList(u8).Writer, .{ .checked_to_fixed_depth = 256 });
const JsonReader = std.json.Reader(std.json.default_buffer_size, std.io.FixedBufferStream([]const u8).Reader);

pub fn requestWithPayload(
    allocator: Allocator,
    comptime meta: anytype,
    comptime member: anytype,
    request: *http.Request,
    value: anytype,
) !void {
    switch (@as(smithy.MetaPayload, meta[0])) {
        .media => {
            request.payload = value;
            try request.putHeader(allocator, "content-type", meta[2]);
        },
        .shape => {
            const required = srl.hasField(member, "required");
            const shape: smithy.SerialType = member.scheme.shape;

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
                    try writeValue(&json, member.scheme, value);
                    request.payload = try payload.toOwnedSlice();
                },
                else => unreachable,
            }
        },
    }
}

pub fn requestWithShape(
    allocator: Allocator,
    comptime members: anytype,
    comptime body_ids: anytype,
    content_type: []const u8,
    request: *http.Request,
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

fn writeStructMember(json: *JsonWriter, comptime member: anytype, struct_value: anytype) !void {
    const member_value = @field(struct_value, member.name_zig);
    const value = if (srl.hasField(member, "required")) member_value else member_value orelse return;

    try json.objectField(member.name_api);
    try writeValue(json, member.scheme, value);
}

fn writeValue(json: *JsonWriter, comptime scheme: anytype, value: anytype) !void {
    switch (@as(smithy.SerialType, scheme.shape)) {
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
            try json.beginArray();
            for (value) |item| {
                if (g == .list_sparse and item == null) {
                    try json.write(null);
                } else {
                    try writeValue(json, scheme.member, item);
                }
            }
            try json.endArray();
        },
        .set => {
            try json.beginArray();
            var it = value.iterator();
            while (it.next()) |item| {
                try writeValue(json, scheme.member, item);
            }
            try json.endArray();
        },
        .map => {
            const is_sparse = srl.hasField(scheme, "sparse");
            try json.beginObject();
            var it = value.iterator();
            while (it.next()) |entry| {
                try json.objectField(entry.key_ptr.*);
                if (is_sparse and entry.value_ptr.* == null) {
                    try json.write(null);
                } else {
                    try writeValue(json, scheme.val, entry.value_ptr.*);
                }
            }
            try json.endObject();
        },
        .int_enum => try json.write(@as(i32, @intFromEnum(value))),
        .str_enum, .trt_enum => try json.write(value.toString()),
        .tagged_union => {
            try json.beginObject();
            switch (value) {
                inline else => |v, g| {
                    const member = comptime blk: {
                        for (scheme.members, 0..) |member, i| {
                            if (mem.eql(u8, member.name_zig, @tagName(g))) break :blk scheme.members[i];
                        }
                        unreachable;
                    };
                    try json.objectField(member.name_api);
                    try writeValue(json, member.scheme, v);
                },
            }
            try json.endObject();
        },
        .structure => {
            try json.beginObject();
            inline for (scheme.members) |member| {
                try writeStructMember(json, member, value);
            }
            try json.endObject();
        },
        .timestamp_epoch_seconds => try json.write(value.asSecFloat()),
        .timestamp_date_time => {
            try json.beginWriteRaw();
            try json.stream.writeByte('\"');
            try srl.writeTimestamp(json.stream.any(), value.epoch_ms);
            try json.stream.writeByte('\"');
            json.endWriteRaw();
        },
        .timestamp_http_date => {
            try json.beginWriteRaw();
            try json.stream.writeByte('\"');
            try srl.writeHttpDate(json.stream.any(), value.epoch_ms);
            try json.stream.writeByte('\"');
            json.endWriteRaw();
        },
        inline else => |g| {
            // document, big_integer, big_decimal
            @compileError("Unimplemted serialization for type " ++ @tagName(g));
        },
    }
}

pub fn responseOutput(
    scratch_alloc: Allocator,
    output_alloc: Allocator,
    comptime scheme: anytype,
    payload: []const u8,
    output: anytype,
) !void {
    if (srl.hasField(scheme.meta, "payload")) {
        const meta = scheme.meta.payload;
        const member = scheme.members[meta[1]];
        try responseWithPayload(scratch_alloc, output_alloc, member, meta[0], payload, output);
    } else if (scheme.body_ids.len > 0) {
        try responseWithShape(scratch_alloc, output_alloc, scheme.members, payload, output);
    } else {
        std.debug.assert(payload.len == 0);
    }
}

fn responseWithPayload(
    scratch_alloc: Allocator,
    output_alloc: Allocator,
    comptime member: anytype,
    comptime kind: smithy.MetaPayload,
    payload: []const u8,
    output: anytype,
) !void {
    switch (@as(smithy.MetaPayload, kind)) {
        .media => output.* = payload,
        .shape => switch (@as(smithy.SerialType, member.scheme.shape)) {
            .string, .blob => output.* = payload,
            .str_enum, .trt_enum => {
                var resolved = srl.ValueType(output).parse(payload);
                switch (resolved) {
                    .UNKNOWN => resolved = .{ .UNKNOWN = try output_alloc.dupe(u8, payload) },
                    else => {},
                }
                @field(output, member.name_zig) = resolved;
            },
            .str_enum, .trt_enum, .document, .structure, .tagged_union => {
                var stream = std.io.fixedBufferStream(payload);
                var reader = std.json.reader(scratch_alloc, stream.reader());
                const required = srl.hasField(member, "required");
                if (!required and .null == try reader.peekNextTokenType()) return;
                try parseStructMemberValue(scratch_alloc, output_alloc, &reader, member.scheme, output);
            },
            else => unreachable,
        },
    }
}

fn responseWithShape(
    scratch_alloc: Allocator,
    output_alloc: Allocator,
    comptime members: anytype,
    payload: []const u8,
    output: anytype,
) !void {
    var stream = std.io.fixedBufferStream(payload);
    var reader = std.json.reader(scratch_alloc, stream.reader());

    if ((try reader.next()) != .object_begin) return error.UnexpectedToken;
    while (try reader.peekNextTokenType() != .object_end) {
        const idx = try findMemberIndex(scratch_alloc, &reader, members) orelse {
            try reader.skipValue();
            continue;
        };
        switch (idx) {
            inline 0...(members.len - 1) => |i| {
                const member = members[i];
                try parseStructMemberValue(scratch_alloc, output_alloc, &reader, member, output);
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
    output: anytype,
) !void {
    switch (@as(smithy.SerialType, scheme.shape)) {
        .boolean => output.* = try std.json.innerParse(bool, scratch_alloc, json, .{}),
        .byte => output.* = try std.json.innerParse(i8, scratch_alloc, json, .{}),
        .short => output.* = try std.json.innerParse(i16, scratch_alloc, json, .{}),
        .integer => output.* = try std.json.innerParse(i32, scratch_alloc, json, .{}),
        .long => output.* = try std.json.innerParse(i64, scratch_alloc, json, .{}),
        .float => output.* = try std.json.innerParse(f32, scratch_alloc, json, .{}),
        .double => output.* = try std.json.innerParse(f64, scratch_alloc, json, .{}),
        .string => {
            output.* = try std.json.innerParse([]const u8, output_alloc, json, .{
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
            output.* = member_value;
        },
        inline .list_dense, .list_sparse => |g| {
            const Child = switch (@typeInfo(@TypeOf(output.*))) {
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
                    try parseValue(scratch_alloc, output_alloc, json, scheme.member, try list.addOne());
                }
            }
            if ((try json.next()) != .array_end) return error.UnexpectedToken;

            output.* = try list.toOwnedSlice();
        },
        .set => {
            const Set = srl.ValueType(output);
            var set = Set{};
            if ((try json.next()) != .array_begin) return error.UnexpectedToken;
            while (try json.peekNextTokenType() != .array_end) {
                var item: Set.Item = undefined;
                try parseValue(scratch_alloc, output_alloc, json, scheme.member, &item);
                try set.internal.putNoClobber(output_alloc, item, {});
            }
            if ((try json.next()) != .array_end) return error.UnexpectedToken;
            output.* = set;
        },
        .map => {
            const HashMap = srl.ValueType(output);
            const Item = std.meta.fieldInfo(HashMap.KV, .value).type;
            const is_sparse = srl.hasField(scheme, "sparse");

            var map = HashMap{};
            if ((try json.next()) != .object_begin) return error.UnexpectedToken;
            while (try json.peekNextTokenType() != .object_end) {
                const key = try std.json.innerParse([]const u8, scratch_alloc, json, .{
                    .allocate = .alloc_if_needed,
                    .max_value_len = std.json.default_max_value_len,
                });

                if (is_sparse and .null == try json.peekNextTokenType()) {
                    try map.internal.putNoClobber(output_alloc, key, null);
                } else {
                    var item: Item = undefined;
                    try parseValue(scratch_alloc, output_alloc, json, scheme.val, &item);
                    try map.internal.putNoClobber(output_alloc, key, item);
                }
            }
            if ((try json.next()) != .object_end) return error.UnexpectedToken;
            output.* = map;
        },
        .int_enum => {
            const Enum = srl.ValueType(output);
            const Int = std.meta.Tag(Enum);
            const int_value = try std.json.innerParse(Int, scratch_alloc, json, .{
                .max_value_len = std.json.default_max_value_len,
            });
            output.* = @enumFromInt(int_value);
        },
        .str_enum, .trt_enum => {
            const str_value = try std.json.innerParse([]const u8, output_alloc, json, .{
                .allocate = .alloc_always,
                .max_value_len = std.json.default_max_value_len,
            });

            const T = srl.ValueType(output);
            const resolved = T.parse(str_value);
            if (resolved != .UNKNOWN) output_alloc.free(str_value);

            output.* = resolved;
        },
        .timestamp_date_time => {
            const str_value = try std.json.innerParse([]const u8, scratch_alloc, json, .{
                .allocate = .alloc_if_needed,
                .max_value_len = std.json.default_max_value_len,
            });
            const epoch_ms = try srl.parseTimestamp(str_value);
            output.* = .{ .epoch_ms = epoch_ms };
        },
        .timestamp_http_date => {
            const str_value = try std.json.innerParse([]const u8, scratch_alloc, json, .{
                .allocate = .alloc_if_needed,
                .max_value_len = std.json.default_max_value_len,
            });
            const epoch_ms = try srl.parseHttpDate(str_value);
            output.* = .{ .epoch_ms = epoch_ms };
        },
        .timestamp_epoch_seconds => {
            switch (try json.nextAlloc(scratch_alloc, .alloc_if_needed)) {
                .number, .allocated_number => |s| {
                    if (mem.indexOfScalar(u8, s, '.') != null) {
                        const dbl = try std.fmt.parseFloat(f64, s);
                        const epoch_ms: i64 = @intFromFloat(dbl * std.time.ms_per_s);
                        output.* = .{ .epoch_ms = epoch_ms };
                    } else {
                        const int = try std.fmt.parseInt(i64, s, 10);
                        const epoch_ms = int * std.time.ms_per_s;
                        output.* = .{ .epoch_ms = epoch_ms };
                    }
                },
                else => unreachable,
            }
        },
        .tagged_union => {
            const Union = srl.ValueType(output);
            if ((try json.next()) != .object_begin) return error.UnexpectedToken;
            if (try findMemberIndex(scratch_alloc, json, scheme.members)) |idx| switch (idx) {
                inline 0...(scheme.members.len - 1) => |i| {
                    const member = scheme.members[i].scheme;
                    var value: std.meta.TagPayloadByName(Union, member.name_zig) = undefined;
                    try parseValue(scratch_alloc, output_alloc, json, member, &value);
                    output.* = @unionInit(Union, member.name_zig, value);
                },
                else => unreachable,
            } else {
                try json.skipValue();
                return;
            }

            if ((try json.next()) != .object_end) return error.UnexpectedToken;
        },
        .structure => {
            const Out = srl.ValueType(output);
            output.* = srl.zeroInit(Out, .{});

            if ((try json.next()) != .object_begin) return error.UnexpectedToken;
            while (try json.peekNextTokenType() != .object_end) {
                const idx = try findMemberIndex(scratch_alloc, json, scheme.members) orelse {
                    try json.skipValue();
                    continue;
                };
                switch (idx) {
                    inline 0...(scheme.members.len - 1) => |i| {
                        const member = scheme.members[i];
                        try parseStructMemberValue(scratch_alloc, output_alloc, json, member, output);
                    },
                    else => unreachable,
                }
            }
            if ((try json.next()) != .object_end) return error.UnexpectedToken;
        },
        inline else => |g| {
            // document, big_integer, big_decimal
            @compileError("Unimplemted parsing for type " ++ @tagName(g));
        },
    }
}

fn findMemberIndex(arena: Allocator, json: *JsonReader, comptime members: anytype) !?usize {
    const key_name = try std.json.innerParse([]const u8, arena, json, .{
        .allocate = .alloc_if_needed,
        .max_value_len = std.json.default_max_value_len,
    });

    if (srl.findMemberIndex(members, key_name)) |i| {
        return i;
    } else {
        // if (@import("builtin").mode == .Debug) log.warn("Unexpected response member: `{s}`", .{key_name});
        return null;
    }
}

fn parseStructMemberValue(
    scratch_alloc: Allocator,
    output_alloc: Allocator,
    json: *JsonReader,
    comptime member: anytype,
    output: anytype,
) !void {
    const required = srl.hasField(member, "required");
    if (!required and .null == try json.peekNextTokenType()) {
        @field(output, member.name_zig) = null;
    } else {
        const field = &@field(output, member.name_zig);
        try parseValue(scratch_alloc, output_alloc, json, member.scheme, field);
    }
}

pub fn responseError(
    scratch_alloc: Allocator,
    output_arena: *ArenaAllocator,
    comptime scheme: anytype,
    comptime E: type,
    response: http.Response,
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

fn parseHeaderError(response: http.Response) ?[]const u8 {
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
