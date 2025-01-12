//! https://smithy.io/2.0/aws/protocols/aws-query-protocol.html
const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const base64 = std.base64.standard;
const Allocator = mem.Allocator;
const xmlib = @import("xml");
const smithy = @import("smithy/runtime");
const srl = smithy.serial;
const xml = @import("xml.zig");
const Request = @import("../http.zig").Request;
const UrlEncode = @import("../utils/url.zig").UrlEncodeFormat;

const log = std.log.scoped(.aws_sdk);

pub fn requestInput(
    allocator: Allocator,
    comptime schema: anytype,
    request: *Request,
    action: []const u8,
    version: []const u8,
    input: anytype,
) !void {
    try request.putHeader(allocator, "content-type", "application/x-www-form-urlencoded");

    var build = try Builder.init(allocator, action, version);
    errdefer build.deinit();

    inline for (schema.body_ids) |i| {
        try writeMember(&build, schema.members[i], input);
    }

    request.payload = try build.consume();
}

const Builder = struct {
    allocator: Allocator,
    query: std.ArrayListUnmanaged(u8) = .{},
    scope: std.ArrayListUnmanaged(UrlEncode) = .{},

    pub fn init(allocator: Allocator, action: []const u8, version: []const u8) !Builder {
        var self = Builder{ .allocator = allocator };
        try self.query.writer(allocator).print("Action={}&Version={}", .{
            UrlEncode{ .value = action },
            UrlEncode{ .value = version },
        });
        return self;
    }

    pub fn deinit(self: *Builder) void {
        self.query.deinit(self.allocator);
        self.scope.deinit(self.allocator);
    }

    pub fn consume(self: *Builder) ![]const u8 {
        defer self.scope.deinit(self.allocator);
        return self.query.toOwnedSlice(self.allocator);
    }

    pub fn pushScope(self: *Builder, scope: []const u8) !void {
        try self.scope.append(.{ .value = scope });
    }

    pub fn popScope(self: *Builder) void {
        _ = self.scope.pop();
    }

    pub fn writeKey(self: *Builder, key: []const u8) !void {
        const w = self.query.writer(self.allocator);
        try w.writeByte('&');
        for (self.scope.items) |scope| {
            try w.print("{}.", .{scope});
        }
        try w.print("{}=", .{UrlEncode{ .value = key }});
    }

    pub fn writeValue(self: *Builder, value: []const u8) !void {
        const w = self.query.writer(self.allocator);
        try w.print("{}", .{UrlEncode{ .value = value }});
    }

    pub fn writeListIndex(self: *Builder, index: usize) !void {
        const w = self.query.writer(self.allocator);
        try w.writeByte('&');
        for (self.scope.items) |scope| {
            try w.print("{}.", .{scope});
        }
        try w.print("{d}=", .{index});
    }
};

fn writeMember(build: *Builder, comptime member: anytype, struct_value: anytype) !void {
    const member_value = @field(struct_value, member.name_zig);
    const value = if (srl.hasField(member, "required")) member_value else member_value orelse return;

    const schema = member.schema;
    switch (@as(smithy.SerialType, schema.shape)) {
        .list_dense, .list_sparse, .set, .map => {
            if (srl.hasField(schema, "flatten")) {
                return writeCollectionItems(build, schema, member.name_api, value);
            } else {
                try build.pushScope(member.name_api);
                defer build.popScope();
                try writeValue(build, schema, value);
            }
        },
        .structure, .tagged_union => {
            try build.pushScope(member.name_api);
            defer build.popScope();
            return writeValue(build, schema, value);
        },
        else => {
            try build.writeKey(member.name_api);
            try writeValue(build, schema, value);
        },
    }
}

fn writeValue(build: *Builder, comptime schema: anytype, value: anytype) !void {
    switch (@as(smithy.SerialType, schema.shape)) {
        .string => try build.writeValue(value),
        .str_enum, .trt_enum => try build.writeValue(value.toString()),
        .boolean => try build.writeValue(if (value) "true" else "false"),
        .float, .double => try writeFloatValue(build, value),
        .byte, .short, .integer, .long => {
            var buf: [20]u8 = undefined;
            try build.writeValue(std.fmt.bufPrintIntToSlice(&buf, value, 10, .lower, .{}));
        },
        .int_enum => {
            var buf: [20]u8 = undefined;
            const int = @as(i32, @intFromEnum(value));
            try build.writeValue(std.fmt.bufPrintIntToSlice(&buf, int, 10, .lower, .{}));
        },
        .timestamp_epoch_seconds => try writeFloatValue(build, value.asSecFloat()),
        .timestamp_date_time => {
            var buf: [srl.timestamp_buffer_len]u8 = undefined;
            var stream = std.io.fixedBufferStream(&buf);
            try srl.writeTimestamp(stream.writer().any(), value.epoch_ms);
            try build.writeValue(stream.getWritten());
        },
        .timestamp_http_date => {
            var buf: [srl.http_date_buffer_len]u8 = undefined;
            var stream = std.io.fixedBufferStream(&buf);
            try srl.writeHttpDate(stream.writer().any(), value.epoch_ms);
            try build.writeValue(stream.getWritten());
        },
        .blob => {
            switch (base64.Encoder.calcSize(value)) {
                0...256 => {
                    var buf: [256]u8 = undefined;
                    try build.writeValue(try base64.Encoder.encode(&buf, value));
                },
                257...4096 => {
                    var buf: [4096]u8 = undefined;
                    try build.writeValue(try base64.Encoder.encode(&buf, value));
                },
                4097...65536 => {
                    var buf: [65536]u8 = undefined;
                    try build.writeValue(try base64.Encoder.encode(&buf, value));
                },
                else => |n| {
                    const buf = try build.allocator.alloc(u8, n);
                    defer build.allocator.free(buf);
                    try build.writeValue(try base64.Encoder.encode(&buf, value));
                },
            }
        },
        .list_dense, .list_sparse, .set => {
            const name = srl.fieldFallback([]const u8, schema, "name_member", "member");
            try writeCollectionItems(build, schema, name, value);
        },
        .map => try writeCollectionItems(build, schema, "entry", value),
        .tagged_union => {
            switch (value) {
                inline else => |v, g| {
                    const member = comptime blk: {
                        for (schema.members, 0..) |member, i| {
                            if (mem.eql(u8, member.name_zig, @tagName(g))) break :blk schema.members[i];
                        }
                        unreachable;
                    };
                    try writeMember(build, member.schema, v);
                },
            }
        },
        .structure => {
            inline for (schema.members) |member| {
                try writeMember(build, member, value);
            }
        },
        .document => unreachable,
        inline else => |g| {
            // big_integer, big_decimal
            @compileError("Unimplemted serialization for type " ++ @tagName(g));
        },
    }
}

fn writeFloatValue(build: *Builder, value: anytype) !void {
    if (std.math.isNan(value)) {
        try build.writeValue("NaN");
    } else if (std.math.inf(@TypeOf(value)) == value) {
        try build.writeValue("Infinity");
    } else if (-std.math.inf(@TypeOf(value)) == value) {
        try build.writeValue("-Infinity");
    } else {
        var buf: [std.fmt.format_float.min_buffer_size]u8 = undefined;
        try build.writeValue(try std.fmt.formatFloat(&buf, value, .{}));
    }
}

fn writeCollectionItems(build: *Builder, comptime collection: anytype, name: []const u8, items: anytype) !void {
    try build.pushScope(name);
    defer build.popScope();

    switch (collection.shape) {
        inline .list_dense, .list_sparse => |g| {
            for (items, 0..) |item, i| {
                if (g == .list_sparse and item == null) continue;
                if (isAggregateShape(collection.member.shape)) {
                    var buf: [20]u8 = undefined;
                    try build.pushScope(std.fmt.bufPrintIntToSlice(&buf, i, 10, .lower, .{}));
                    defer build.popScope();
                    try writeValue(build, collection.member, item);
                } else {
                    try build.writeListIndex(i);
                    try writeValue(build, collection.member, item);
                }
            }
        },
        .set => {
            var i: isize = 0;
            var it = items.iterator();
            while (it.next()) |item| : (i += 1) {
                if (isAggregateShape(collection.member.shape)) {
                    var buf: [20]u8 = undefined;
                    try build.pushScope(std.fmt.bufPrintIntToSlice(&buf, i, 10, .lower, .{}));
                    defer build.popScope();
                    try writeValue(build, collection.member, item);
                } else {
                    try build.writeListIndex(i);
                    try writeValue(build, collection.member, item);
                }
            }
        },
        .map => {
            const is_sparse = srl.hasField(collection, "sparse");
            const key_name = srl.fieldFallback([]const u8, collection, "name_key", "key");
            const key_aggregate = isAggregateShape(collection.key.shape);
            const value_name = srl.fieldFallback([]const u8, collection, "name_value", "value");
            const value_aggregate = isAggregateShape(collection.val.shape);

            var i: usize = 0;
            var it = items.iterator();
            while (it.next()) |entry| : (i += 1) {
                if (is_sparse and entry.value_ptr.* == null) continue;

                var buf: [20]u8 = undefined;
                try build.pushScope(std.fmt.bufPrintIntToSlice(&buf, i, 10, .lower, .{}));
                defer build.popScope();

                if (key_aggregate) {
                    try build.pushScope(key_name);
                    defer build.popScope();
                    try writeValue(build, collection.key, entry.key_ptr.*);
                } else {
                    try build.writeKey(key_name);
                    try writeValue(build, collection.key, entry.key_ptr.*);
                }

                if (value_aggregate) {
                    try build.pushScope(value_name);
                    defer build.popScope();
                    try writeValue(build, collection.val, entry.value_ptr.*);
                } else {
                    try build.writeKey(value_name);
                    try writeValue(build, collection.val, entry.value_ptr.*);
                }
            }
        },
        else => unreachable,
    }
}

fn isAggregateShape(shape: smithy.SerialType) bool {
    return switch (shape) {
        .list_dense, .list_sparse, .set, .map, .structure, .tagged_union => true,
        else => false,
    };
}

pub fn responseOutput(
    scratch_alloc: Allocator,
    output_alloc: Allocator,
    comptime schema: anytype,
    payload: []const u8,
    output: anytype,
) !void {
    var doc = xmlib.StaticDocument.init(payload);
    var reader = doc.reader(scratch_alloc, .{}).reader;
    defer reader.deinit();

    try reader.skipProlog();
    if (!mem.endsWith(u8, reader.elementName(), "Response")) {
        @branchHint(.cold);
        return error.UnexpectedNode;
    }

    while (true) {
        try xml.expectNode(&reader, .element_start);
        if (mem.endsWith(u8, reader.elementName(), "Result")) {
            try xml.parseStruct(scratch_alloc, output_alloc, &reader, schema, output);
            try reader.skipElement();
            break;
        } else {
            try reader.skipElement();
        }
    }

    try xml.expectNode(&reader, .element_end);
    try xml.expectNode(&reader, .eof);
}
