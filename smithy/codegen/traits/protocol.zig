//! Serialization and Protocol traits
//!
//! [Smithy Spec](https://smithy.io/2.0/spec/protocol-traits.html)
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
    // smithy.api#protocolDefinition
    .{ JsonName.id, JsonName.parse },
    .{ MediaType.id, MediaType.parse },
    .{ TimestampFormat.id, TimestampFormat.parse },
    .{ xml_attribute_id, null },
    .{ xml_flattened_id, null },
    .{ XmlName.id, XmlName.parse },
    .{ XmlNamespace.id, XmlNamespace.parse },
};

/// Allows a serialized object property name in a JSON document to differ from a
/// structure or union member name used in the model.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/protocol-traits.html#jsonname-trait)
pub const JsonName = StringTrait("smithy.api#jsonName");

/// Describes the contents of a blob or string shape using a design-time media
/// type as defined by [RFC 6838](https://datatracker.ietf.org/doc/html/rfc6838.html).
///
/// [Smithy Spec](https://smithy.io/2.0/spec/protocol-traits.html#mediatype-trait)
pub const MediaType = StringTrait("smithy.api#mediaType");

/// Serializes an object property as an XML attribute rather than a nested XML element.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/protocol-traits.html#xmlattribute-trait)
pub const xml_attribute_id = SmithyId.of("smithy.api#xmlAttribute");

/// Unwraps the values of a list or map into the containing structure.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/protocol-traits.html#xmlflattened-trait)
pub const xml_flattened_id = SmithyId.of("smithy.api#xmlFlattened");

/// Changes the serialized element or attribute name of a structure, union, or member.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/protocol-traits.html#xmlname-trait)
pub const XmlName = StringTrait("smithy.api#xmlName");

/// Adds an [XML namespace](https://www.w3.org/TR/REC-xml-names/) to an XML element.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/protocol-traits.html#xmlnamespace-trait)
pub const XmlNamespace = struct {
    pub const id = SmithyId.of("smithy.api#xmlNamespace");

    pub const Val = struct {
        /// The namespace URI for scoping this XML element.
        uri: []const u8,
        /// The namespace prefix for elements from this namespace.
        prefix: ?[]const u8 = null,
    };

    pub fn parse(arena: Allocator, reader: *JsonReader) !*const anyopaque {
        var val = Val{ .uri = undefined };

        var required: usize = 1;
        try reader.nextObjectBegin();
        while (try reader.peek() != .object_end) {
            const prop = try reader.nextString();
            if (mem.eql(u8, "uri", prop)) {
                val.uri = try reader.nextStringAlloc(arena);
                required -= 1;
            } else if (mem.eql(u8, "prefix", prop)) {
                val.prefix = try reader.nextStringAlloc(arena);
            } else {
                std.log.warn("Unknown xml namespace trait property `{s}`", .{prop});
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

test XmlNamespace {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    var reader = try JsonReader.initFixed(arena_alloc,
        \\{
        \\  "uri": "http://foo.com",
        \\  "prefix": "baz"
        \\}
    );
    const val: *const XmlNamespace.Val = @alignCast(@ptrCast(XmlNamespace.parse(arena_alloc, &reader) catch |e| {
        reader.deinit();
        return e;
    }));
    reader.deinit();
    try testing.expectEqualDeep(&XmlNamespace.Val{
        .uri = "http://foo.com",
        .prefix = "baz",
    }, val);
}

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
