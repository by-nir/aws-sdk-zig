//! AWS Protocols
//!
//! [Smithy Spec](https://smithy.io/2.0/aws/protocols/index.html#aws-protocols)
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const smithy = @import("smithy/codegen");
const SmithyId = smithy.SmithyId;
const JsonReader = smithy.JsonReader;
const TraitsRegistry = smithy.TraitsRegistry;
const SymbolsProvider = smithy.SymbolsProvider;

// TODO: Remainig traits
pub const traits: TraitsRegistry = &.{
    .{ AwsJson10.id, AwsJson10.parse },
    .{ AwsJson11.id, AwsJson11.parse },
    .{ aws_query_id, null },
    // aws.protocols#awsQueryCompatible // Intentionally not implemented (used by SQS, but not relevant for our implementation)
    .{ AwsQueryError.id, AwsQueryError.parse },
    // aws.protocols#ec2Query
    // aws.protocols#ec2QueryName
    // aws.protocols#httpChecksum
    .{ RestJson1.id, RestJson1.parse },
    .{ RestXml.id, RestXml.parse },
};

/// This specification defines the _AWS JSON 1.0_ protocol.
///
/// [Smithy Spec](https://smithy.io/2.0/aws/protocols/aws-json-1_0-protocol.html)
pub const AwsJson10 = JsonTrait("aws.protocols#awsJson1_0");

/// This specification defines the _AWS JSON 1.1_ protocol.
///
/// [Smithy Spec](https://smithy.io/2.0/aws/protocols/aws-json-1_1-protocol.html)
pub const AwsJson11 = JsonTrait("aws.protocols#awsJson1_1");

/// This specification defines the AWS _Query_ protocol.
///
/// [Smithy Spec](https://smithy.io/2.0/aws/protocols/aws-query-protocol.html)
pub const aws_query_id = SmithyId.of("aws.protocols#awsQuery");

/// This specification defines the _AWS restJson1_ protocol. This protocol is used
/// to expose services that serialize payloads as JSON and utilize features of
/// HTTP like configurable HTTP methods, URIs, and status codes.
///
/// [Smithy Spec](https://smithy.io/2.0/aws/protocols/aws-restjson1-protocol.html)
pub const RestJson1 = JsonTrait("aws.protocols#restJson1");

/// Provides a custom _Code_ value for _AWS Query_ protocol errors and an HTTP response code.
///
/// [Smithy Spec](https://smithy.io/2.0/aws/protocols/aws-query-protocol.html#aws-protocols-awsqueryerror-trait)
pub const AwsQueryError = struct {
    pub const id = SmithyId.of("aws.protocols#awsQueryError");

    pub const Value = struct {
        /// The value used to distinguish this error shape during client deserialization.
        code: []const u8,
        /// The HTTP response code used on a response that contains this error shape.
        http_status: std.http.Status,
    };

    pub fn parse(arena: Allocator, reader: *JsonReader) !*const anyopaque {
        const value = try arena.create(Value);
        errdefer arena.destroy(value);

        var required: usize = 2;
        try reader.nextObjectBegin();
        while (try reader.peek() != .object_end) {
            const prop = try reader.nextString();
            if (mem.eql(u8, prop, "code")) {
                value.code = try reader.nextStringAlloc(arena);
                required -= 1;
            } else if (mem.eql(u8, prop, "httpResponseCode")) {
                value.http_status = @enumFromInt(@as(u10, @intCast(try reader.nextInteger())));
                required -= 1;
            } else {
                std.log.warn("Unknown `AWS query error` trait property `{s}`", .{prop});
                try reader.skipValueOrScope();
            }
        }
        try reader.nextObjectEnd();

        if (required > 0) return error.AwsQueryErrorMissingRequiredProperties;
        return value;
    }

    pub fn get(symbols: *SymbolsProvider, shape_id: SmithyId) ?*const Value {
        return symbols.getTrait(Value, shape_id, id);
    }
};

test AwsQueryError {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    var reader = try JsonReader.initFixed(arena_alloc,
        \\{
        \\    "code": "foo",
        \\    "httpResponseCode": 404
        \\}
    );
    errdefer reader.deinit();

    const json: *const AwsQueryError.Value = @ptrCast(@alignCast(try AwsQueryError.parse(arena_alloc, &reader)));
    reader.deinit();
    try testing.expectEqualDeep(&AwsQueryError.Value{
        .code = "foo",
        .http_status = .not_found,
    }, json);
}

fn JsonTrait(comptime trait_id: []const u8) type {
    return struct {
        pub const id = SmithyId.of(trait_id);

        pub const Value = struct {
            /// The priority ordered list of supported HTTP protocol versions.
            http: ?[]const []const u8 = null,
            /// The priority ordered list of supported HTTP protocol versions that
            /// are required when using [event streams](https://smithy.io/2.0/spec/streaming.html#event-streams)
            /// with the service.
            event_stream_http: ?[]const []const u8 = null,
        };

        pub fn parse(arena: Allocator, reader: *JsonReader) !*const anyopaque {
            const value = try arena.create(Value);
            errdefer arena.destroy(value);
            value.* = .{};

            try reader.nextObjectBegin();
            while (try reader.peek() != .object_end) {
                const prop = try reader.nextString();
                if (mem.eql(u8, prop, "http")) {
                    value.http = try parseStringList(arena, reader);
                } else if (mem.eql(u8, prop, "eventStreamHttp")) {
                    value.event_stream_http = try parseStringList(arena, reader);
                } else {
                    std.log.warn("Unknown `" ++ trait_id ++ "` trait property `{s}`", .{prop});
                    try reader.skipValueOrScope();
                }
            }
            try reader.nextObjectEnd();

            return value;
        }

        pub fn get(symbols: *SymbolsProvider, shape_id: SmithyId) ?*const Value {
            return symbols.getTrait(Value, shape_id, id);
        }
    };
}

fn parseStringList(arena: Allocator, reader: *JsonReader) ![]const []const u8 {
    var list = std.ArrayList([]const u8).init(arena);
    errdefer list.deinit();

    try reader.nextArrayBegin();
    while (try reader.peek() != .array_end) {
        try list.append(try reader.nextStringAlloc(arena));
    }
    try reader.nextArrayEnd();

    return list.toOwnedSlice();
}

test JsonTrait {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    var reader = try JsonReader.initFixed(arena_alloc,
        \\{
        \\    "http": [ "h2", "http/1.1" ],
        \\    "eventStreamHttp": ["h2"]
        \\}
    );
    errdefer reader.deinit();

    const TestJson = JsonTrait("smithy.api#testJson");
    const json: *const TestJson.Value = @ptrCast(@alignCast(try TestJson.parse(arena_alloc, &reader)));
    reader.deinit();
    try testing.expectEqualDeep(&TestJson.Value{
        .http = &.{ "h2", "http/1.1" },
        .event_stream_http = &.{"h2"},
    }, json);
}

/// This specification defines the AWS _restXml_ protocol.
///
/// [Smithy Spec](https://smithy.io/2.0/aws/protocols/aws-restxml-protocol.html)
pub const RestXml = struct {
    pub const id = SmithyId.of("aws.protocols#restXml");

    pub const Value = struct {
        /// The priority ordered list of supported HTTP protocol versions.
        http: ?[]const []const u8 = null,
        /// The priority ordered list of supported HTTP protocol versions that
        /// are required when using [event streams](https://smithy.io/2.0/spec/streaming.html#event-streams)
        /// with the service.
        event_stream_http: ?[]const []const u8 = null,
        /// Disables the wrapping of error properties in an `ErrorResponse` XML element.
        no_error_wrapping: bool = false,
    };

    pub fn parse(arena: Allocator, reader: *JsonReader) !*const anyopaque {
        const value = try arena.create(Value);
        errdefer arena.destroy(value);
        value.* = .{};

        try reader.nextObjectBegin();
        while (try reader.peek() != .object_end) {
            const prop = try reader.nextString();
            if (mem.eql(u8, prop, "http")) {
                value.http = try parseStringList(arena, reader);
            } else if (mem.eql(u8, prop, "eventStreamHttp")) {
                value.event_stream_http = try parseStringList(arena, reader);
            } else if (mem.eql(u8, prop, "noErrorWrapping")) {
                value.no_error_wrapping = try reader.nextBoolean();
            } else {
                std.log.warn("Unknown `rest xml` trait property `{s}`", .{prop});
                try reader.skipValueOrScope();
            }
        }
        try reader.nextObjectEnd();

        return value;
    }

    pub fn get(symbols: *SymbolsProvider, shape_id: SmithyId) ?*const Value {
        return symbols.getTrait(Value, shape_id, id);
    }
};

test RestXml {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    var reader = try JsonReader.initFixed(arena_alloc,
        \\{
        \\    "http": [ "h2", "http/1.1" ],
        \\    "eventStreamHttp": ["h2"],
        \\    "noErrorWrapping": true
        \\}
    );
    errdefer reader.deinit();

    const json: *const RestXml.Value = @ptrCast(@alignCast(try RestXml.parse(arena_alloc, &reader)));
    reader.deinit();
    try testing.expectEqualDeep(&RestXml.Value{
        .http = &.{ "h2", "http/1.1" },
        .event_stream_http = &.{"h2"},
        .no_error_wrapping = true,
    }, json);
}
