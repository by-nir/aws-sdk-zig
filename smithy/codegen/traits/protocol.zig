//! Serialization and Protocol traits
//!
//! [Smithy Spec](https://smithy.io/2.0/spec/protocol-traits.html)
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const mdl = @import("../model.zig");
const SmithyId = mdl.SmithyId;
const SymbolsProvider = @import("../systems/SymbolsProvider.zig");
const TraitsRegistry = @import("../systems/traits.zig").TraitsRegistry;
const JsonReader = @import("../utils/JsonReader.zig");

// TODO: Remainig traits
pub const registry: TraitsRegistry = &.{
    // smithy.api#protocolDefinition
    // smithy.api#jsonName
    // smithy.api#mediaType
    .{ TimestampFormat.id, TimestampFormat.parse },
    // smithy.api#xmlAttribute
    // smithy.api#xmlFlattened
    // smithy.api#xmlName
    // smithy.api#xmlNamespace
};

/// Defines an optional custom timestamp serialization format.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/protocol-traits.html#timestamp-formats)
pub const TimestampFormat = struct {
    pub const id = SmithyId.of("smithy.api#timestampFormat");

    pub const Value = enum {
        /// Date time as defined by the date-time production in RFC 3339 (section 5.6),
        /// with optional millisecond precision but no UTC offset.
        /// ```
        /// 1985-04-12T23:20:50.520Z
        /// ```
        date_time,
        /// An HTTP date as defined by the IMF-fixdate production in RFC 7231 (section 7.1.1.1).
        /// ```
        /// Tue, 29 Apr 2014 18:30:38 GMT
        /// ```
        http_date,
        /// Also known as Unix time, the number of seconds that have elapsed since
        /// _00:00:00 Coordinated Universal Time (UTC), Thursday, 1 January 1970_,
        /// with optional millisecond precision.
        /// ```
        /// 1515531081.123
        /// ```
        epoch_seconds,
    };

    pub fn parse(arena: Allocator, reader: *JsonReader) !*const anyopaque {
        const source = try reader.nextString();

        var enum_val: Value = undefined;
        if (mem.eql(u8, "date-time", source)) {
            enum_val = .http_date;
        } else if (mem.eql(u8, "http-date", source)) {
            enum_val = .http_date;
        } else if (mem.eql(u8, "epoch-seconds", source)) {
            enum_val = .epoch_seconds;
        } else {
            return error.UnkownTimestampFormat;
        }

        const value = try arena.create(Value);
        value.* = enum_val;
        return value;
    }

    pub fn get(symbols: *SymbolsProvider, shape_id: SmithyId) ?Value {
        return symbols.getTrait(Value, shape_id, id);
    }
};

test TimestampFormat {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    var reader = try JsonReader.initFixed(arena_alloc, "\"http-date\"");
    const val: *const TimestampFormat.Value = @alignCast(@ptrCast(TimestampFormat.parse(arena_alloc, &reader) catch |e| {
        reader.deinit();
        return e;
    }));
    reader.deinit();
    try testing.expectEqualDeep(&TimestampFormat.Value.http_date, val);
}
