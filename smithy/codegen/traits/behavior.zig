//! Behavior traits
//!
//! [Smithy Spec](https://smithy.io/2.0/spec/behavior-traits.html)
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const SmithyId = @import("../model.zig").SmithyId;
const JsonReader = @import("../utils/JsonReader.zig");
const trt = @import("../systems/traits.zig");
const TraitsRegistry = trt.TraitsRegistry;
const SymbolsProvider = @import("../systems/SymbolsProvider.zig");

// TODO: Remainig traits
pub const registry: TraitsRegistry = &.{
    // smithy.api#idempotencyToken
    // smithy.api#idempotent
    // smithy.api#readonly
    .{ retryable_id, null },
    .{ Paginated.id, Paginated.parse },
    // smithy.api#requestCompression
};

/// Indicates that an error MAY be retried by the client.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/behavior-traits.html#retryable-trait)
pub const retryable_id = SmithyId.of("smithy.api#retryable");

/// Indicates that an operation intentionally limits the number of results returned in a
/// single response and that multiple invocations might be necessary to retrieve all results.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/behavior-traits.html#pagination)
pub const Paginated = struct {
    pub const id = SmithyId.of("smithy.api#paginated");

    pub const Val = struct {
        /// The name of the operation input member that contains a continuation token.
        input_token: ?[]const u8 = null,
        /// The path to the operation output member that contains an optional continuation token.
        output_token: ?[]const u8 = null,
        /// The path to an output member of the operation that contains the data
        /// that is being paginated across many responses.
        items: ?[]const u8 = null,
        /// The name of an operation input member that limits the maximum number
        /// of results to include in the operation output.
        page_size: ?[]const u8 = null,

        pub fn isPartial(self: Val) bool {
            return self.input_token == null or
                self.output_token == null or
                self.items == null or
                self.page_size == null;
        }
    };

    pub fn parse(arena: Allocator, reader: *JsonReader) !*const anyopaque {
        var val = Val{};
        try reader.nextObjectBegin();
        while (try reader.peek() != .object_end) {
            const prop = try reader.nextString();
            if (mem.eql(u8, "inputToken", prop)) {
                val.input_token = try reader.nextStringAlloc(arena);
            } else if (mem.eql(u8, "outputToken", prop)) {
                val.output_token = try reader.nextStringAlloc(arena);
            } else if (mem.eql(u8, "items", prop)) {
                val.items = try reader.nextStringAlloc(arena);
            } else if (mem.eql(u8, "pageSize", prop)) {
                val.page_size = try reader.nextStringAlloc(arena);
            } else {
                std.log.warn("Unknown paginated trait property `{s}`", .{prop});
                try reader.skipValueOrScope();
            }
        }
        try reader.nextObjectEnd();

        const value = try arena.create(Val);
        value.* = val;
        return value;
    }

    pub fn get(symbols: *SymbolsProvider, shape_id: SmithyId) ?Val {
        const val = symbols.getTrait(Val, shape_id, id) orelse return null;
        return val.*;
    }
};

test Paginated {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    var reader = try JsonReader.initFixed(arena_alloc,
        \\{
        \\    "inputToken": "foo",
        \\    "outputToken": "bar",
        \\    "items": "baz",
        \\    "pageSize": "qux"
        \\}
    );

    const val_int: *const Paginated.Val = @alignCast(@ptrCast(Paginated.parse(arena_alloc, &reader) catch |e| {
        reader.deinit();
        return e;
    }));
    reader.deinit();
    try testing.expectEqualDeep(&Paginated.Val{
        .input_token = "foo",
        .output_token = "bar",
        .items = "baz",
        .page_size = "qux",
    }, val_int);
}
