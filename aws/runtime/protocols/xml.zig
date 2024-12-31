//! - https://smithy.io/2.0/aws/protocols/aws-restxml-protocol.html
//! - https://smithy.io/2.0/spec/protocol-traits.html#xml-bindings
const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const base64 = std.base64.standard;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const xmlib = @import("xml");
const smithy = @import("smithy/runtime");
const srl = smithy.serial;
const http = @import("../http.zig");

const log = std.log.scoped(.aws_sdk);

pub fn requestWithPayload(
    allocator: Allocator,
    comptime meta: anytype,
    comptime member: anytype,
    request: *http.Request,
    input: anytype,
) !void {
    switch (@as(smithy.MetaPayload, meta[0])) {
        .media => {
            request.payload = input;
            try request.putHeader(allocator, "content-type", meta[2]);
        },
        .shape => {
            const required = srl.hasField(member, "required");
            const shape: smithy.SerialType = member.scheme.shape;

            try request.putHeader(allocator, "content-type", switch (shape) {
                .blob => "application/octet-stream",
                .str_enum, .trt_enum, .string => "text/plain",
                .structure, .tagged_union => "application/xml",
                else => unreachable,
            });

            switch (shape) {
                .string, .blob => request.payload = input,
                .str_enum, .trt_enum => request.payload = input.toString(),
                .structure, .tagged_union => {
                    if (!required and input == null) return;

                    var payload = std.ArrayList(u8).init(allocator);
                    const payload_writer = payload.writer();
                    errdefer payload.deinit();

                    var xml = xmlib.Writer.init(allocator, xmlWriter(&payload_writer), .{
                        .namespace_aware = false,
                    });
                    defer xml.deinit();

                    try writeValue(&xml, member.scheme, input);
                    request.payload = try payload.toOwnedSlice();
                },
                else => unreachable,
            }
        },
    }
}

pub fn requestWithShape(allocator: Allocator, comptime scheme: anytype, request: *http.Request, input: anytype) !void {
    try request.putHeader(allocator, "content-type", "application/xml");

    var payload = std.ArrayList(u8).init(allocator);
    const payload_writer = payload.writer();
    errdefer payload.deinit();

    var xml = xmlib.Writer.init(allocator, xmlWriter(&payload_writer), .{
        .namespace_aware = false,
    });
    defer xml.deinit();

    try xml.xmlDeclaration("UTF-8", null);

    try writeElementStart(&xml, scheme);
    if (srl.hasField(scheme, "attr_ids")) inline for (scheme.attr_ids) |i| {
        try writeStructAttribute(&xml, scheme.members[i], input);
    };
    inline for (scheme.body_ids) |i| {
        try writeStructMember(&xml, scheme.members[i], input);
    }
    try xml.elementEnd();

    request.payload = try payload.toOwnedSlice();
}

fn xmlWriter(writer: *const std.ArrayList(u8).Writer) xmlib.Writer.Sink {
    return .{
        .context = writer,
        .writeFn = struct {
            fn f(context: *const anyopaque, data: []const u8) anyerror!void {
                const buf: *const std.ArrayList(u8).Writer = @ptrCast(@alignCast(context));
                try buf.writeAll(data);
            }
        }.f,
    };
}

fn writeElementStart(xml: *xmlib.Writer, member: anytype) !void {
    try xml.elementStart(member.name_api);
    if (srl.hasField(member, "ns_url")) {
        const prefix = if (srl.hasField(member, "ns_prefix")) member.ns_prefix else null;
        try writeNamespaceAttr(xml, member.ns_url, prefix);
    }
}

// The XML lib’s handling of namespaces is weird, so we need to do this manually.
fn writeNamespaceAttr(xml: *xmlib.Writer, url: []const u8, prefix: ?[]const u8) !void {
    if (prefix) |pref| {
        const attr = try std.fmt.allocPrint(xml.gpa, "xmlns:{s}", .{pref});
        defer xml.gpa.free(attr);
        try xml.attribute(attr, url);
    } else {
        try xml.attribute("xmlns", url);
    }
}

fn writeStructAttribute(xml: *xmlib.Writer, comptime member: anytype, struct_value: anytype) !void {
    const member_value = @field(struct_value, member.name_zig);
    const value = if (srl.hasField(member, "required")) member_value else member_value orelse return;
    try writeStringValue(xml, member.scheme, value, member.api_name);
}

fn writeStructMember(xml: *xmlib.Writer, comptime member: anytype, struct_value: anytype) !void {
    const member_value = @field(struct_value, member.name_zig);
    const value = if (srl.hasField(member, "required")) member_value else member_value orelse return;

    const flat_collection = switch (@as(smithy.SerialType, member.scheme.shape)) {
        .list_dense, .list_sparse, .set, .map => srl.hasField(member.scheme, "flatten"),
        else => false,
    };

    if (flat_collection) {
        const ns_url: ?[]const u8, const ns_prefix: ?[]const u8 = blk: {
            if (srl.hasField(member, "ns_url"))
                break :blk .{
                    member.ns_url,
                    if (srl.hasField(member, "ns_prefix")) member.ns_prefix else null,
                }
            else
                break :blk .{ null, null };
        };

        try writeCollectionItems(xml, member.scheme, member.name_api, value, ns_url, ns_prefix);
    } else {
        try writeElementStart(xml, member);
        try writeValue(xml, member.scheme, value);
        try xml.elementEnd();
    }
}

fn writeValue(xml: *xmlib.Writer, comptime scheme: anytype, value: anytype) !void {
    switch (@as(smithy.SerialType, scheme.shape)) {
        .string,
        .str_enum,
        .trt_enum,
        .boolean,
        .float,
        .double,
        .byte,
        .short,
        .integer,
        .long,
        .int_enum,
        .timestamp_epoch_seconds,
        .timestamp_date_time,
        .timestamp_http_date,
        => try writeStringValue(xml, scheme, value, null),
        .blob => {
            switch (base64.Encoder.calcSize(value)) {
                0...256 => {
                    var buf: [256]u8 = undefined;
                    try xml.text(try base64.Encoder.encode(&buf, value));
                },
                257...4096 => {
                    var buf: [4096]u8 = undefined;
                    try xml.text(try base64.Encoder.encode(&buf, value));
                },
                4097...65536 => {
                    var buf: [65536]u8 = undefined;
                    try xml.text(try base64.Encoder.encode(&buf, value));
                },
                else => |n| {
                    const buf = try xml.gpa.alloc(u8, n);
                    defer xml.gpa.free(buf);
                    try xml.text(try base64.Encoder.encode(&buf, value));
                },
            }
        },
        .list_dense, .list_sparse, .set => {
            const name = srl.fieldFallback([]const u8, scheme, "name_member", "member");
            try writeCollectionItems(xml, scheme, name, value, null, null);
        },
        .map => try writeCollectionItems(xml, scheme, "entry", value, null, null),
        .tagged_union => {
            try writeElementStart(xml, scheme);
            switch (value) {
                inline else => |v, g| {
                    const member = comptime blk: {
                        for (scheme.members, 0..) |member, i| {
                            if (mem.eql(u8, member.name_zig, @tagName(g))) break :blk scheme.members[i];
                        }
                        unreachable;
                    };
                    try writeStructMember(xml, member.scheme, v);
                },
            }
            try xml.elementEnd();
        },
        .structure => {
            try writeElementStart(xml, scheme);
            if (srl.hasField(scheme, "attr_ids")) {
                inline for (scheme.attr_ids) |i| {
                    try writeStructAttribute(xml, scheme.members[i], value);
                }
                inline for (scheme.body_ids) |i| {
                    try writeStructMember(xml, scheme.members[i], value);
                }
            } else {
                inline for (scheme.members) |member| {
                    try writeStructMember(xml, member, value);
                }
            }
            try xml.elementEnd();
        },
        .document => unreachable,
        inline else => |g| {
            // big_integer, big_decimal
            @compileError("Unimplemted serialization for type " ++ @tagName(g));
        },
    }
}

fn writeStringValue(xml: *xmlib.Writer, comptime scheme: anytype, value: anytype, attr: ?[]const u8) !void {
    switch (@as(smithy.SerialType, scheme.shape)) {
        .string => try writeAttributeOrText(xml, value, attr),
        .str_enum, .trt_enum => try writeAttributeOrText(xml, value.toString(), attr),
        .boolean => try writeAttributeOrText(xml, if (value) "true" else "false", attr),
        .float, .double => try writeFloatValue(xml, value, attr),
        .byte, .short, .integer, .long => {
            var buf: [20]u8 = undefined;
            try writeAttributeOrText(xml, std.fmt.bufPrintIntToSlice(&buf, value, 10, .lower, .{}), attr);
        },
        .int_enum => {
            var buf: [20]u8 = undefined;
            const int = @as(i32, @intFromEnum(value));
            try writeAttributeOrText(xml, std.fmt.bufPrintIntToSlice(&buf, int, 10, .lower, .{}), attr);
        },
        .timestamp_epoch_seconds => try writeFloatValue(xml, value.asSecFloat(), attr),
        .timestamp_date_time => {
            var buf: [srl.timestamp_buffer_len]u8 = undefined;
            var stream = std.io.fixedBufferStream(&buf);
            try srl.writeTimestamp(stream.writer().any(), value.epoch_ms);
            try writeAttributeOrText(xml, stream.getWritten(), attr);
        },
        .timestamp_http_date => {
            var buf: [srl.http_date_buffer_len]u8 = undefined;
            var stream = std.io.fixedBufferStream(&buf);
            try srl.writeHttpDate(stream.writer().any(), value.epoch_ms);
            try writeAttributeOrText(xml, stream.getWritten(), attr);
        },
    }
}

fn writeFloatValue(xml: *xmlib.Writer, value: anytype, attr: ?[]const u8) !void {
    if (std.math.isNan(value)) {
        try writeAttributeOrText(xml, "NaN", attr);
    } else if (std.math.inf(@TypeOf(value)) == value) {
        try writeAttributeOrText(xml, "Infinity", attr);
    } else if (-std.math.inf(@TypeOf(value)) == value) {
        try writeAttributeOrText(xml, "-Infinity", attr);
    } else {
        var buf: [std.fmt.format_float.min_buffer_size]u8 = undefined;
        try writeAttributeOrText(xml, try std.fmt.formatFloat(&buf, value, .{}), attr);
    }
}

fn writeAttributeOrText(xml: *xmlib.Writer, value: []const u8, attr: ?[]const u8) !void {
    if (attr) |name| try xml.attribute(name, value) else try xml.text(value);
}

fn writeCollectionItems(
    xml: *xmlib.Writer,
    comptime collection: anytype,
    name: []const u8,
    items: anytype,
    ns_url: ?[]const u8,
    ns_prefix: ?[]const u8,
) !void {
    switch (collection.shape) {
        inline .list_dense, .list_sparse => |g| {
            for (items) |item| {
                try xml.elementStart(name);
                if (ns_url) |url| try writeNamespaceAttr(xml, url, ns_prefix);
                if (g == .list_sparse and item == null) {
                    try xml.elementEndEmpty();
                } else {
                    try writeValue(xml, collection.member, item);
                    try xml.elementEnd();
                }
            }
        },
        .set => {
            var it = items.iterator();
            while (it.next()) |item| {
                try xml.elementStart(name);
                if (ns_url) |url| try writeNamespaceAttr(xml, url, ns_prefix);
                try writeValue(xml, collection.scheme, item);
                try xml.elementEnd();
            }
        },
        .map => {
            const is_sparse = srl.hasField(collection, "sparse");
            const key_name = srl.fieldFallback([]const u8, collection, "name_key", "key");
            const value_name = srl.fieldFallback([]const u8, collection, "name_value", "value");

            var it = items.iterator();
            while (it.next()) |entry| {
                try xml.elementStart(name);
                if (ns_url) |url| try writeNamespaceAttr(xml, url, ns_prefix);

                try xml.elementStart(key_name);
                try writeValue(xml, collection.key, entry.key_ptr.*);
                try xml.elementEnd();

                try xml.elementStart(value_name);
                if (is_sparse and entry.value_ptr.* == null) {
                    try xml.elementEndEmpty();
                } else {
                    try writeValue(xml, collection.val, entry.value_ptr.*);
                    try xml.elementEnd();
                }

                try xml.elementEnd();
            }
        },
        else => unreachable,
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
        try responseWithShape(scratch_alloc, output_alloc, scheme, payload, output);
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
            .structure, .tagged_union => {
                var doc = xmlib.StaticDocument.init(payload);
                var reader = doc.reader(scratch_alloc, .{}).reader;
                defer reader.deinit();

                try reader.skipProlog();
                if (mem.eql(u8, reader.elementName(), member.name_api)) {
                    const next_started = try parseMember(scratch_alloc, output_alloc, &reader, member, .element, output);
                    std.debug.assert(!next_started);
                } else {
                    @branchHint(.cold);
                    return error.UnexpectedNode;
                }
                try expectNode(&reader, .eof);
            },
            else => unreachable,
        },
    }
}

fn responseWithShape(
    scratch_alloc: Allocator,
    output_alloc: Allocator,
    comptime scheme: anytype,
    payload: []const u8,
    output: anytype,
) !void {
    var doc = xmlib.StaticDocument.init(payload);
    var reader = doc.reader(scratch_alloc, .{}).reader;
    defer reader.deinit();

    try reader.skipProlog();
    if (mem.eql(u8, reader.elementName(), scheme.name_api)) {
        try parseStruct(scratch_alloc, output_alloc, &reader, scheme, output);
    } else {
        @branchHint(.cold);
        return error.UnexpectedNode;
    }
    try expectNode(&reader, .eof);
}

const ParseSource = union(enum) {
    attribute: usize,
    element,
};

pub fn parseStruct(
    scratch_alloc: Allocator,
    output_alloc: Allocator,
    xml: *xmlib.Reader,
    comptime scheme: anytype,
    output: anytype,
) !void {
    const Out = srl.ValueType(output);
    output.* = srl.zeroInit(Out, .{});

    const attr_len = xml.attributeCount();
    if (srl.hasField(scheme, "attr_ids")) for (0..attr_len) |i| {
        const next_started = try parseStructMember(
            scratch_alloc,
            output_alloc,
            xml,
            scheme.members,
            xml.attributeName(i),
            .{ .attribute = i },
            output,
        );
        std.debug.assert(!next_started);
    };

    var next = try xml.read();
    while (true) {
        switch (next) {
            .element_start => {
                @branchHint(.likely);
                const next_started = try parseStructMember(
                    scratch_alloc,
                    output_alloc,
                    xml,
                    scheme.members,
                    xml.elementName(),
                    .element,
                    output,
                );

                // When a flatten collection start reading the next member we skip one read.
                if (next_started) continue;
            },
            .element_end => break,
            .text => {},
            .comment => {
                @branchHint(.unlikely);
            },
            else => {
                @branchHint(.cold);
                return error.UnexpectedNode;
            },
        }

        next = try xml.read();
    }
}

/// Returns `true` when the following element start is already read.
fn parseStructMember(
    scratch_alloc: Allocator,
    output_alloc: Allocator,
    xml: *xmlib.Reader,
    comptime members: anytype,
    name: []const u8,
    source: ParseSource,
    output: anytype,
) !bool {
    const idx = findMemberIndex(members, name) orelse {
        try xml.skipElement();
        return false;
    };

    switch (idx) {
        inline 0...(members.len - 1) => |i| {
            const member = members[i];
            return parseMember(scratch_alloc, output_alloc, xml, member, source, output);
        },
        else => unreachable,
    }
}

fn findMemberIndex(comptime members: anytype, name: []const u8) ?usize {
    return srl.findMemberIndex(members, name) orelse {
        // if (@import("builtin").mode == .Debug) log.warn("Unexpected response node: `{s}`", .{name});
        return null;
    };
}

/// Returns `true` when the following element start is already read.
fn parseMember(
    scratch_alloc: Allocator,
    output_alloc: Allocator,
    xml: *xmlib.Reader,
    comptime member: anytype,
    source: ParseSource,
    output: anytype,
) !bool {
    const required = srl.hasField(member, "required");
    if (!required and xml.state == .empty_element) {
        @field(output, member.name_zig) = null;
        try expectNode(xml, .element_end);
        return false;
    }

    const T = @FieldType(@TypeOf(output.*), member.name_zig);
    var field: switch (@typeInfo(T)) {
        .optional => |m| m.child,
        else => T,
    } = undefined;
    defer @field(output, member.name_zig) = field;

    switch (@as(smithy.SerialType, member.scheme.shape)) {
        .list_dense, .list_sparse, .set, .map => {
            if (srl.hasField(member.scheme, "flatten")) {
                return parseCollectionValue(scratch_alloc, output_alloc, xml, member.scheme, member.name_api, &field);
            }
        },
        else => {},
    }

    try parseValue(scratch_alloc, output_alloc, xml, member.scheme, source, &field);
    return false;
}

fn parseValue(
    scratch_alloc: Allocator,
    output_alloc: Allocator,
    xml: *xmlib.Reader,
    comptime scheme: anytype,
    source: ParseSource,
    output: anytype,
) !void {
    switch (@as(smithy.SerialType, scheme.shape)) {
        .boolean => output.* = mem.eql(u8, "true", try readStringValue(xml, source, null)),
        .byte => output.* = try std.fmt.parseInt(i8, try readStringValue(xml, source, null), 10),
        .short => output.* = try std.fmt.parseInt(i16, try readStringValue(xml, source, null), 10),
        .integer => output.* = try std.fmt.parseInt(i32, try readStringValue(xml, source, null), 10),
        .long => output.* = try std.fmt.parseInt(i64, try readStringValue(xml, source, null), 10),
        .float => output.* = try std.fmt.parseFloat(f32, try readStringValue(xml, source, null)),
        .double => output.* = try std.fmt.parseFloat(f64, try readStringValue(xml, source, null)),
        .string => output.* = try readStringValue(xml, source, output_alloc),
        .int_enum => {
            const Int = std.meta.Tag(srl.ValueType(output));
            const int_value = try std.fmt.parseInt(Int, try readStringValue(xml, source, null), 10);
            output.* = @enumFromInt(int_value);
        },
        .str_enum, .trt_enum => {
            const str_value = try readStringValue(xml, source, null);
            const resolved = srl.ValueType(output).parse(str_value);
            output.* = switch (resolved) {
                .UNKNOWN => .{ .UNKNOWN = try output_alloc.dupe(u8, str_value) },
                else => resolved,
            };
        },
        .blob => {
            const str_value = try readStringValue(xml, source, null);
            const size = try base64.Decoder.calcSizeForSlice(str_value);
            const member_value = try output_alloc.alloc(u8, size);
            try base64.Decoder.decode(member_value, str_value);
            output.* = member_value;
        },
        .timestamp_date_time => output.* = .{ .epoch_ms = try srl.parseTimestamp(try readStringValue(xml, source, null)) },
        .timestamp_http_date => output.* = .{ .epoch_ms = try srl.parseHttpDate(try readStringValue(xml, source, null)) },
        .timestamp_epoch_seconds => {
            const str_value = try readStringValue(xml, source, null);
            if (mem.indexOfScalar(u8, str_value, '.') != null) {
                const dbl = try std.fmt.parseFloat(f64, str_value);
                const epoch_ms: i64 = @intFromFloat(dbl * std.time.ms_per_s);
                output.* = .{ .epoch_ms = epoch_ms };
            } else {
                const int = try std.fmt.parseInt(i64, str_value, 10);
                const epoch_ms = int * std.time.ms_per_s;
                output.* = .{ .epoch_ms = epoch_ms };
            }
        },
        .list_dense, .list_sparse, .set => {
            const next_started = try parseCollectionValue(scratch_alloc, output_alloc, xml, scheme, null, output);
            std.debug.assert(!next_started);
        },
        .map => {
            const next_started = try parseCollectionValue(scratch_alloc, output_alloc, xml, scheme, null, output);
            std.debug.assert(!next_started);
        },
        .tagged_union => {
            const Union = srl.ValueType(output);
            try expectNode(xml, .element_start);
            try expectNode(xml, .element_start);
            const idx = findMemberIndex(scheme.members, xml.elementName()) orelse {
                try xml.skipElement();
                return;
            };
            switch (idx) {
                inline 0...(scheme.members.len - 1) => |i| {
                    const member = scheme.members[i];
                    const is_flat = switch (@as(smithy.SerialType, member.scheme.shape)) {
                        .list_dense, .list_sparse, .set, .map => srl.hasField(member.scheme, "flatten"),
                        else => false,
                    };

                    var value: std.meta.TagPayloadByName(Union, member.name_zig) = undefined;
                    if (is_flat) {
                        const next_started = try parseCollectionValue(
                            scratch_alloc,
                            output_alloc,
                            xml,
                            member.scheme,
                            member.name_api,
                            &value,
                        );
                        std.debug.assert(!next_started);
                    } else {
                        try parseValue(scratch_alloc, output_alloc, xml, member.scheme, source, &value);
                    }

                    output.* = @unionInit(Union, member.name_zig, value);
                },
                else => unreachable,
            }
            try expectNode(xml, .element_end);
        },
        .structure => try parseStruct(scratch_alloc, output_alloc, xml, scheme, output),
        .document => unreachable,
        inline else => |g| {
            // big_integer, big_decimal
            @compileError("Unimplemted parsing for type " ++ @tagName(g));
        },
    }
}

/// Only provide `name` if flatten!
///
/// Returns `true` when the following element start is already read.
fn parseCollectionValue(
    scratch_alloc: Allocator,
    output_alloc: Allocator,
    xml: *xmlib.Reader,
    comptime collection: anytype,
    name: ?[]const u8,
    output: anytype,
) !bool {
    const is_flat = name != null;
    switch (collection.shape) {
        inline .list_dense, .list_sparse => |g| {
            const Child = switch (@typeInfo(@TypeOf(output.*))) {
                .pointer => |m| m.child,
                .optional => |m| @typeInfo(m.child).pointer.child,
                else => unreachable,
            };
            var did_start_next = false;
            var list = std.ArrayList(Child).init(output_alloc);
            loop: switch (if (is_flat) .start else try expectElementStart(xml, null)) {
                .start => {
                    if (g == .list_sparse and xml.state == .empty_element) {
                        try list.append(null);
                        try expectNode(xml, .element_end);
                    } else {
                        try parseValue(scratch_alloc, output_alloc, xml, collection.member, .element, try list.addOne());
                    }
                    continue :loop try expectElementStart(xml, name);
                },
                .end => did_start_next = false,
                .mismatch => if (is_flat) {
                    did_start_next = true;
                } else unreachable,
            }
            output.* = try list.toOwnedSlice();
            return did_start_next;
        },
        .set => {
            const Set = srl.ValueType(output);
            var set = Set{};
            var did_start_next = false;
            loop: switch (if (is_flat) .start else try expectElementStart(xml, null)) {
                .start => {
                    var item: Set.Item = undefined;
                    try parseValue(scratch_alloc, output_alloc, xml, collection.member, .element, &item);
                    try set.internal.putNoClobber(output_alloc, item, {});
                    continue :loop try expectElementStart(xml, name);
                },
                .end => did_start_next = false,
                .mismatch => if (is_flat) {
                    did_start_next = true;
                } else unreachable,
            }
            output.* = set;
            return did_start_next;
        },
        .map => {
            const HashMap = srl.ValueType(output);
            const Item = std.meta.fieldInfo(HashMap.KV, .value).type;
            const is_sparse = srl.hasField(collection, "sparse");

            var map = HashMap{};
            var did_start_next = false;
            loop: switch (if (is_flat) .start else try expectElementStart(xml, null)) {
                .start => {
                    try expectNode(xml, .element_start);
                    // We must allocate since reading the value element will invalid the key element.
                    const key = try xml.readElementTextAlloc(scratch_alloc);
                    defer scratch_alloc.free(key);

                    try expectNode(xml, .element_start);
                    if (is_sparse and xml.state == .empty_element) {
                        try map.internal.putNoClobber(output_alloc, key, null);
                        try expectNode(xml, .element_end);
                    } else {
                        var item: Item = undefined;
                        try parseValue(scratch_alloc, output_alloc, xml, collection.val, .element, &item);
                        try map.internal.putNoClobber(output_alloc, key, item);
                    }

                    try expectNode(xml, .element_end);
                    continue :loop try expectElementStart(xml, name);
                },
                .end => did_start_next = false,
                .mismatch => if (is_flat) {
                    did_start_next = true;
                } else unreachable,
            }
            output.* = map;
            return did_start_next;
        },
        else => unreachable,
    }
}

fn readStringValue(xml: *xmlib.Reader, source: ParseSource, allocator: ?Allocator) ![]const u8 {
    return switch (source) {
        .element => if (allocator) |alc| xml.readElementTextAlloc(alc) else xml.readElementText(),
        .attribute => |idx| if (allocator) |alc| xml.attributeValueAlloc(alc, idx) else xml.attributeValue(idx),
    };
}

const ExpectElementState = enum {
    mismatch,
    start,
    end,
};

fn expectElementStart(xml: *xmlib.Reader, name: ?[]const u8) !ExpectElementState {
    while (true) switch (try xml.read()) {
        .element_start => {
            const expect = name orelse return .start;
            return if (mem.eql(u8, expect, xml.elementName())) .start else .mismatch;
        },
        .element_end => return .end,
        .text => {},
        .comment => {
            @branchHint(.unlikely);
        },
        else => {
            @branchHint(.cold);
            return error.UnexpectedNode;
        },
    };
}

pub fn expectNode(xml: *xmlib.Reader, comptime node: xmlib.Reader.Node) !void {
    while (true) switch (try xml.read()) {
        node => return,
        .text => {},
        .comment => {
            @branchHint(.unlikely);
        },
        else => {
            @branchHint(.cold);
            return error.UnexpectedNode;
        },
    };
}

pub fn responseError(
    scratch_alloc: Allocator,
    output_arena: *ArenaAllocator,
    comptime scheme: anytype,
    comptime E: type,
    response: http.Response,
    has_wrap: bool,
) !smithy.ResultError(E) {
    var doc = xmlib.StaticDocument.init(response.body);
    var reader = doc.reader(scratch_alloc, .{}).reader;
    defer reader.deinit();

    const map = comptime blk: {
        const members = scheme[1];
        var entries: [members.len]struct { []const u8, E } = undefined;
        for (members, 0..) |entry, i| {
            entries[i] = .{ entry[0], std.enums.nameCast(E, entry[1]) };
        }
        break :blk std.StaticStringMap(E).initComptime(entries);
    };

    try reader.skipProlog();
    if (has_wrap) {
        if (mem.eql(u8, "ErrorResponse", reader.elementName())) {
            try expectNode(&reader, .element_start);
        } else {
            @branchHint(.cold);
            return error.UnexpectedNode;
        }
    }

    var code: ?E = null;
    var msg: ?[]const u8 = null;
    while (true) switch (try reader.read()) {
        .element_start => {
            const field = reader.elementName();
            if (mem.eql(u8, "Code", field)) {
                const text = try reader.readElementText();
                code = map.get(text) orelse {
                    log.err("Unresolved response error: `{s}`", .{text});
                    return error.UnresolvedResponseError;
                };
            } else if (mem.eql(u8, "Message", field)) {
                msg = try reader.readElementTextAlloc(output_arena.allocator());
            }

            try expectNode(&reader, .element_end);
        },
        .element_end => break,
        .text => {},
        .comment => {
            @branchHint(.unlikely);
        },
        else => {
            @branchHint(.cold);
            return error.UnexpectedNode;
        },
    };

    if (has_wrap) try expectNode(&reader, .element_end);
    try expectNode(&reader, .eof);

    var output = smithy.ResultError(E){
        .kind = code orelse return error.UnresolvedResponseError,
    };

    if (msg) |s| {
        output.message = s;
        output.arena = output_arena.*;
    }

    return output;
}
