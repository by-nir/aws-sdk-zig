//! Smithy provides various HTTP binding traits that can be used by protocols to
//! explicitly configure HTTP request and response messages.
//!
//! [Smithy Spec](https://smithy.io/2.0/spec/http-bindings.html)
const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const symbols = @import("../systems/symbols.zig");
const SmithyId = symbols.SmithyId;
const SmithyModel = symbols.SmithyModel;
const TraitsRegistry = @import("../systems/traits.zig").TraitsRegistry;
const JsonReader = @import("../utils/JsonReader.zig");

// TODO: Remainig traits
pub const traits: TraitsRegistry = &.{
    // smithy.api#http
    .{ HttpError.id, HttpError.parse },
    // smithy.api#httpHeader
    // smithy.api#httpLabel
    // smithy.api#httpPayload
    // smithy.api#httpPrefixHeaders
    // smithy.api#httpQuery
    // smithy.api#httpQueryParams
    // smithy.api#httpResponseCode
    // smithy.api#cors
    // smithy.api#httpChecksumRequired
};

/// Defines an HTTP response code for an operation error.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/http-bindings.html#httperror-trait)
pub const HttpError = struct {
    pub const id = SmithyId.of("smithy.api#httpError");

    pub fn parse(arena: Allocator, reader: *JsonReader) !*const anyopaque {
        const value = try arena.create(u10);
        value.* = @intCast(try reader.nextInteger());
        return value;
    }

    pub fn get(model: *const SmithyModel, shape_id: SmithyId) ?u10 {
        return model.getTrait(u10, shape_id, id);
    }
};

test "HttpError" {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const allocator = arena.allocator();
    defer arena.deinit();

    var reader = try JsonReader.initFixed(allocator, "429");
    const val_int: *const u10 = @alignCast(@ptrCast(HttpError.parse(allocator, &reader) catch |e| {
        reader.deinit();
        return e;
    }));
    reader.deinit();
    try testing.expectEqualDeep(&@as(u10, 429), val_int);
}
