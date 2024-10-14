//! Smithy provides various HTTP binding traits that can be used by protocols to
//! explicitly configure HTTP request and response messages.
//!
//! [Smithy Spec](https://smithy.io/2.0/spec/http-bindings.html)
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const SmithyId = @import("../model.zig").SmithyId;
const trt = @import("../systems/traits.zig");
const StringTrait = trt.StringTrait;
const TraitsRegistry = trt.TraitsRegistry;
const SymbolsProvider = @import("../systems/SymbolsProvider.zig");
const JsonReader = @import("../utils/JsonReader.zig");

pub const registry: TraitsRegistry = &.{
    // smithy.api#cors
    .{ Http.id, Http.parse },
    .{ HttpError.id, HttpError.parse },
    .{ HttpHeader.id, HttpHeader.parse },
    .{ http_label_id, null },
    .{ http_payload_id, null },
    .{ HttpPrefixHeaders.id, HttpPrefixHeaders.parse },
    .{ HttpQuery.id, HttpQuery.parse },
    .{ http_query_params_id, null },
    .{ http_response_code_id, null },
    .{ http_checksum_required_id, null },
};

/// Binds a structure member to an HTTP header.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/http-bindings.html#httpheader-trait)
pub const HttpHeader = StringTrait("smithy.api#httpHeader");

/// Binds an operation input structure member to an _HTTP label_ so that it is
/// used as part of an HTTP request URI.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/http-bindings.html#httplabel-trait)
pub const http_label_id = SmithyId.of("smithy.api#httpLabel");

/// Binds a single structure member to the body of an HTTP message.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/http-bindings.html#httppayload-trait)
pub const http_payload_id = SmithyId.of("smithy.api#httpPayload");

/// Binds a map of key-value pairs to prefixed HTTP headers.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/http-bindings.html#httpprefixheaders-trait)
pub const HttpPrefixHeaders = StringTrait("smithy.api#httpPrefixHeaders");

/// Binds an operation input structure member to a query string parameter.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/http-bindings.html#httpquery-trait)
pub const HttpQuery = StringTrait("smithy.api#httpQuery");

/// Binds a map of key-value pairs to query string parameters.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/http-bindings.html#httpqueryparams-trait)
pub const http_query_params_id = SmithyId.of("smithy.api#httpQueryParams");

/// Binds a structure member to the HTTP response status code so that an HTTP
/// response status code can be set dynamicallyat runtime to something other
/// than code of the _http_ trait.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/http-bindings.html#httpresponsecode-trait)
pub const http_response_code_id = SmithyId.of("smithy.api#httpResponseCode");

/// Indicates that an operation requires a checksum in its HTTP request.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/http-bindings.html#httpchecksumrequired-trait)
pub const http_checksum_required_id = SmithyId.of("smithy.api#httpChecksumRequired");

/// Configures the HTTP bindings of an operation.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/http-bindings.html#http-trait)
pub const Http = struct {
    pub const id = SmithyId.of("smithy.api#http");

    pub const Val = struct {
        method: std.http.Method = undefined,
        uri: []const u8 = undefined,
        code: ?std.http.Status = null,
    };

    pub fn parse(arena: Allocator, reader: *JsonReader) !*const anyopaque {
        var val = Val{};
        var required: usize = 2;
        try reader.nextObjectBegin();
        while (try reader.peek() != .object_end) {
            const prop = try reader.nextString();
            if (mem.eql(u8, "method", prop)) {
                val.method = @enumFromInt(std.http.Method.parse(try reader.nextString()));
                required -= 1;
            } else if (mem.eql(u8, "uri", prop)) {
                val.uri = try reader.nextStringAlloc(arena);
                required -= 1;
            } else if (mem.eql(u8, "code", prop)) {
                val.code = @enumFromInt(@as(u10, @intCast(try reader.nextInteger())));
            } else {
                std.log.warn("Unknown length trait property `{s}`", .{prop});
                try reader.skipValueOrScope();
            }
        }
        try reader.nextObjectEnd();

        if (required > 0) return error.MissingRequiredProperties;

        const value = try arena.create(Val);
        value.* = val;
        return value;
    }

    pub fn get(symbols: *SymbolsProvider, shape_id: SmithyId) ?Val {
        const val = symbols.getTrait(Val, shape_id, id) orelse return null;
        return val.*;
    }
};

test Http {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    var reader = try JsonReader.initFixed(arena_alloc,
        \\{
        \\  "method": "GET",
        \\  "uri": "/",
        \\  "code": 200
        \\}
    );
    const val: *const Http.Val = @alignCast(@ptrCast(Http.parse(arena_alloc, &reader) catch |e| {
        reader.deinit();
        return e;
    }));
    reader.deinit();
    try testing.expectEqualDeep(&Http.Val{
        .method = .GET,
        .uri = "/",
        .code = .ok,
    }, val);
}

/// Defines an HTTP response code for an operation error.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/http-bindings.html#httperror-trait)
pub const HttpError = struct {
    pub const id = SmithyId.of("smithy.api#httpError");

    pub fn parse(arena: Allocator, reader: *JsonReader) !*const anyopaque {
        const value = try arena.create(std.http.Status);
        value.* = @enumFromInt(@as(u10, @intCast(try reader.nextInteger())));
        return value;
    }

    pub fn get(symbols: *SymbolsProvider, shape_id: SmithyId) ?std.http.Status {
        return symbols.getTrait(std.http.Status, shape_id, id);
    }
};

test HttpError {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const allocator = arena.allocator();
    defer arena.deinit();

    var reader = try JsonReader.initFixed(allocator, "429");
    const val_int: *const std.http.Status = @alignCast(@ptrCast(HttpError.parse(allocator, &reader) catch |e| {
        reader.deinit();
        return e;
    }));
    reader.deinit();
    try testing.expectEqualDeep(&std.http.Status.too_many_requests, val_int);
}
