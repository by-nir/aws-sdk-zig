const std = @import("std");
const testing = std.testing;
const idHash = std.hash.CityHash32.hash;
const prelude = @import("prelude.zig");

/// A 32-bit hash of a Shape ID.
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
pub const SmithyId = enum(u32) {
    /// We use a constant to avoid handling the NULL case in the switch.
    pub const NULL: SmithyId = @enumFromInt(0);

    unit = idHash("unitType"),
    blob = idHash("blob"),
    boolean = idHash("boolean"),
    string = idHash("string"),
    str_enum = idHash("enum"),
    byte = idHash("byte"),
    short = idHash("short"),
    integer = idHash("integer"),
    int_enum = idHash("intEnum"),
    long = idHash("long"),
    float = idHash("float"),
    double = idHash("double"),
    big_integer = idHash("bigInteger"),
    big_decimal = idHash("bigDecimal"),
    timestamp = idHash("timestamp"),
    document = idHash("document"),
    list = idHash("list"),
    map = idHash("map"),
    structure = idHash("structure"),
    tagged_union = idHash("union"),
    operation = idHash("operation"),
    resource = idHash("resource"),
    service = idHash("service"),
    apply = idHash("apply"),
    _,

    /// Type name or absalute shape id.
    pub fn of(shape_id: []const u8) SmithyId {
        return switch (idHash(shape_id)) {
            idHash(prelude.TYPE_UNIT) => .unit,
            idHash(prelude.TYPE_BLOB) => .blob,
            idHash(prelude.TYPE_STRING) => .string,
            idHash(prelude.TYPE_BOOL), idHash(prelude.PRIMITIVE_BOOL) => .boolean,
            idHash(prelude.TYPE_BYTE), idHash(prelude.PRIMITIVE_BYTE) => .byte,
            idHash(prelude.TYPE_SHORT), idHash(prelude.PRIMITIVE_SHORT) => .short,
            idHash(prelude.TYPE_INT), idHash(prelude.PRIMITIVE_INT) => .integer,
            idHash(prelude.TYPE_LONG), idHash(prelude.PRIMITIVE_LONG) => .long,
            idHash(prelude.TYPE_FLOAT), idHash(prelude.PRIMITIVE_FLOAT) => .float,
            idHash(prelude.TYPE_DOUBLE), idHash(prelude.PRIMITIVE_DOUBLE) => .double,
            idHash(prelude.TYPE_BIGINT) => .big_integer,
            idHash(prelude.TYPE_BIGDEC) => .big_decimal,
            idHash(prelude.TYPE_TIMESTAMP) => .timestamp,
            idHash(prelude.TYPE_DOCUMENT) => .document,
            else => |h| @enumFromInt(h),
        };
    }

    /// `smithy.example.foo#ExampleShapeName$memberName`
    pub fn compose(shape: []const u8, member: []const u8) SmithyId {
        var buffer: [128]u8 = undefined;
        const len = shape.len + member.len + 1;
        std.debug.assert(len <= buffer.len);
        @memcpy(buffer[0..shape.len], shape);
        buffer[shape.len] = '$';
        @memcpy(buffer[shape.len + 1 ..][0..member.len], member);
        return @enumFromInt(idHash(buffer[0..len]));
    }
};

test SmithyId {
    try testing.expectEqual(.boolean, SmithyId.of("boolean"));
    try testing.expectEqual(.boolean, SmithyId.of("smithy.api#Boolean"));
    try testing.expectEqual(.boolean, SmithyId.of("smithy.api#PrimitiveBoolean"));
    try testing.expectEqual(.list, SmithyId.of("list"));
    try testing.expectEqual(
        @as(SmithyId, @enumFromInt(0x6f8b5d99)),
        SmithyId.of("smithy.example.foo#ExampleShapeName$memberName"),
    );
    try testing.expectEqual(
        SmithyId.of("smithy.example.foo#ExampleShapeName$memberName"),
        SmithyId.compose("smithy.example.foo#ExampleShapeName", "memberName"),
    );
}
