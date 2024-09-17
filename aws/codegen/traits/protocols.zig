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
    // aws.protocols#awsQuery
    // aws.protocols#awsQueryCompatible
    // aws.protocols#awsQueryError
    // aws.protocols#ec2Query
    // aws.protocols#ec2QueryName
    // aws.protocols#httpChecksum
    // aws.protocols#restJson1
    // aws.protocols#restXml
};

/// This specification defines the AWS JSON 1.0 protocol.
///
/// [Smithy Spec](https://smithy.io/2.0/aws/protocols/aws-json-1_0-protocol.html)
pub const AwsJson10 = AwsJsonTrait("aws.protocols#awsJson1_0");

/// This specification defines the AWS JSON 1.1 protocol.
///
/// [Smithy Spec](https://smithy.io/2.0/aws/protocols/aws-json-1_1-protocol.html)
pub const AwsJson11 = AwsJsonTrait("aws.protocols#awsJson1_1");

fn AwsJsonTrait(comptime trait_id: []const u8) type {
    return struct {
        pub const id = SmithyId.of(trait_id);
        pub const auth_id = smithy.traits.auth.AuthId.of(trait_id);

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

test AwsJsonTrait {
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

    const TestJson = AwsJsonTrait("smithy.api#testJson");
    const json: *const TestJson.Value = @ptrCast(@alignCast(try TestJson.parse(arena_alloc, &reader)));
    reader.deinit();
    try testing.expectEqualDeep(&TestJson.Value{
        .http = &.{ "h2", "http/1.1" },
        .event_stream_http = &.{"h2"},
    }, json);
}
