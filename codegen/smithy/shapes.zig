const std = @import("std");
const testing = std.testing;
const test_alloc = testing.allocator;
const prelude = @import("prelude.zig");

/// Hashed shape identifier.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/model.html#shape-id)
/// ```
/// smithy.example.foo#ExampleShapeName$memberName
/// └────────┬───────┘ └───────┬──────┘ └────┬───┘
///      Namespace           Shape        Member
///                    └────────────┬────────────┘
///                         Relative shape ID
/// └─────────────────────┬──────────────────────┘
///               Absolute shape ID
/// ```
pub const ShapeId = enum(u32) {
    blob = hash32("blob"),
    boolean = hash32("boolean"),
    string = hash32("string"),
    @"enum" = hash32("enum"),
    byte = hash32("byte"),
    short = hash32("short"),
    integer = hash32("integer"),
    int_enum = hash32("intEnum"),
    long = hash32("long"),
    float = hash32("float"),
    double = hash32("double"),
    big_integer = hash32("bigInteger"),
    big_decimal = hash32("bigDecimal"),
    timestamp = hash32("timestamp"),
    document = hash32("document"),
    list = hash32("list"),
    map = hash32("map"),
    structure = hash32("structure"),
    @"union" = hash32("union"),
    unit = hash32("unitType"),
    _,

    /// Type name or absalute shape id.
    pub fn full(id: []const u8) ShapeId {
        const hash = hash32(id);
        return switch (hash) {
            hash32(prelude.TYPE_UNIT) => .unit,
            hash32(prelude.TYPE_BLOB) => .blob,
            hash32(prelude.TYPE_BOOL) => .boolean,
            hash32(prelude.TYPE_STRING) => .string,
            hash32(prelude.TYPE_BYTE) => .byte,
            hash32(prelude.TYPE_SHORT) => .short,
            hash32(prelude.TYPE_INT) => .integer,
            hash32(prelude.TYPE_LONG) => .long,
            hash32(prelude.TYPE_FLOAT) => .float,
            hash32(prelude.TYPE_DOUBLE) => .double,
            hash32(prelude.TYPE_BIGINT) => .big_integer,
            hash32(prelude.TYPE_BIGDEC) => .big_decimal,
            hash32(prelude.TYPE_TIMESTAMP) => .timestamp,
            hash32(prelude.TYPE_DOCUMENT) => .document,
            else => @enumFromInt(hash),
        };
    }

    /// `smithy.example.foo#ExampleShapeName` + `memberName`
    pub fn compose(shape: []const u8, member: []const u8) ShapeId {
        var buffer: [128]u8 = undefined;
        const len = shape.len + member.len + 1;
        std.debug.assert(len <= buffer.len);
        @memcpy(buffer[0..shape.len], shape);
        buffer[shape.len] = '$';
        @memcpy(buffer[shape.len + 1 ..][0..member.len], member);
        return @enumFromInt(hash32(buffer[0..len]));
    }

    fn hash32(value: []const u8) u32 {
        return std.hash.CityHash32.hash(value);
    }
};

test "ShapeId" {
    try testing.expectEqual(.blob, ShapeId.full("blob"));
    try testing.expectEqual(.blob, ShapeId.full("smithy.api#Blob"));
    try testing.expectEqual(.list, ShapeId.full("list"));
    try testing.expectEqual(
        @as(ShapeId, @enumFromInt(0x6f8b5d99)),
        ShapeId.full("smithy.example.foo#ExampleShapeName$memberName"),
    );
    try testing.expectEqual(
        ShapeId.full("smithy.example.foo#ExampleShapeName$memberName"),
        ShapeId.compose("smithy.example.foo#ExampleShapeName", "memberName"),
    );
}

/// [Simple](https://smithy.io/2.0/spec/simple-types.html#simple-types) or
/// [Aggregate](https://smithy.io/2.0/spec/aggregate-types.html#aggregate-types) shape.
pub const SmithyType = union(enum) {
    /// The singular unit type in Smithy is similar to Void and None in other languages.
    /// It is used when the input or output of an operation has no meaningful value
    /// or if a union member has no meaningful value. It MUST NOT be referenced
    /// in any other context.
    ///
    /// [Smithy Spec](https://smithy.io/2.0/spec/model.html#unit-type)
    unit,

    //
    // Simple types are types that do not contain nested types or shape references.
    //

    /// Uninterpreted binary data.
    blob,
    /// Boolean value type.
    boolean,
    /// UTF-8 encoded string.
    string,
    /// A string with a fixed set of values.
    @"enum": []const ShapeId,
    /// 8-bit signed integer ranging from -128 to 127 (inclusive).
    byte,
    /// 16-bit signed integer ranging from -32,768 to 32,767 (inclusive).
    short,
    /// 32-bit signed integer ranging from -2^31 to (2^31)-1 (inclusive).
    integer,
    /// An integer with a fixed set of values.
    int_enum: []const ShapeId,
    /// 64-bit signed integer ranging from -2^63 to (2^63)-1 (inclusive).
    long,
    /// Single precision IEEE-754 floating point number.
    float,
    /// Double precision IEEE-754 floating point number.
    double,
    /// Arbitrarily large signed integer.
    big_integer,
    /// Arbitrary precision signed decimal number.
    big_decimal,
    /// An instant in time with no UTC offset or timezone.
    timestamp,
    /// Open content that functions as a kind of "any" type.
    document,

    //
    // Aggregate types contain configurable member references to others shapes.
    //

    /// Ordered collection of homogeneous values.
    list: ShapeId,
    /// Map data structure that maps string keys to homogeneous values.
    map: [2]ShapeId,
    /// Fixed set of named heterogeneous members.
    structure: []const ShapeId,
    /// Tagged union data structure that can take on one of several different, but fixed, types.
    @"union": []const ShapeId,
};

/// Single Smithy model parsed from a single JSON AST.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/json-ast.html)
pub const Model = struct {
    shapes: std.AutoHashMapUnmanaged(ShapeId, SmithyType),

    pub fn getShape(self: Model, id: ShapeId) ?SmithyType {
        return self.shapes.get(id);
    }
};

test "Model" {
    var shapes: std.AutoHashMapUnmanaged(ShapeId, SmithyType) = .{};
    defer shapes.deinit(test_alloc);

    try shapes.put(test_alloc, ShapeId.full("test.simple#Blob"), .blob);
    const model = Model{ .shapes = shapes };

    try testing.expectEqual(.blob, model.getShape(ShapeId.full("test.simple#Blob")));
}
