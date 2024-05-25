const std = @import("std");
const testing = std.testing;
const prelude = @import("../prelude.zig");
const shapes = @import("shapes.zig");

pub const IdHashInt = u32;
pub const idHash = std.hash.CityHash32.hash;

pub const SmithyTaggedValue = struct {
    id: SmithyId,
    value: ?*const anyopaque,
};

pub const SmithyRefMapValue = struct {
    name: []const u8,
    shape: SmithyId,
};

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
pub const SmithyId = enum(IdHashInt) {
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
    tagged_uinon = idHash("union"),
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

test "SmithyId" {
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

/// A Smithy shape’s type.
pub const SmithyType = union(enum) {
    /// A reference to a shape that is not a member of the prelude.
    target: SmithyId,

    /// The singular unit type in Smithy is similar to Void and None in other languages.
    /// It is used when the input or output of an operation has no meaningful value
    /// or if a union member has no meaningful value. It MUST NOT be referenced
    /// in any other context.
    ///
    /// [Smithy Spec](https://smithy.io/2.0/spec/model.html#unit-type)
    unit,

    //
    // Simple types are types that do not contain nested types or shape references.
    // https://smithy.io/2.0/spec/simple-types.html#simple-types
    //

    /// Uninterpreted binary data.
    blob,
    /// Boolean value type.
    boolean,
    /// UTF-8 encoded string.
    string,
    /// A string with a fixed set of values.
    str_enum: []const SmithyId,
    /// 8-bit signed integer ranging from -128 to 127 (inclusive).
    byte,
    /// 16-bit signed integer ranging from -32,768 to 32,767 (inclusive).
    short,
    /// 32-bit signed integer ranging from -2^31 to (2^31)-1 (inclusive).
    integer,
    /// An integer with a fixed set of values.
    int_enum: []const SmithyId,
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
    // https://smithy.io/2.0/spec/aggregate-types.html#aggregate-types
    //

    /// Ordered collection of homogeneous values.
    list: SmithyId,
    /// Map data structure that maps string keys to homogeneous values.
    map: [2]SmithyId,
    /// Fixed set of named heterogeneous members.
    structure: []const SmithyId,
    /// Tagged union data structure that can take on one of several different, but fixed, types.
    tagged_uinon: []const SmithyId,

    //
    // Service types have specific semantics and define services, resources, and operations.
    // https://smithy.io/2.0/spec/service-types.html#service-types
    //

    /// The operation type represents the input, output, and possible errors of an API operation.
    operation: *const shapes.SmithyOperation,
    /// Smithy defines a resource as an entity with an identity that has a set of operations.
    resource: *const shapes.SmithyResource,
    /// A service is the entry point of an API that aggregates resources and operations together.
    service: *const shapes.SmithyService,
};

/// All known Smithy properties.
// NOTICE: If adding more properties, make sure their first 8 characters are unique.
pub const SmithyProperty = enum(u64) {
    collection_ops = parse("collectionOperations"),
    create = parse("create"),
    delete = parse("delete"),
    errors = parse("errors"),
    identifiers = parse("identifiers"),
    input = parse("input"),
    key = parse("key"),
    list = parse("list"),
    member = parse("member"),
    members = parse("members"),
    metadata = parse("metadata"),
    mixins = parse("mixins"),
    operations = parse("operations"),
    output = parse("output"),
    properties = parse("properties"),
    put = parse("put"),
    read = parse("read"),
    rename = parse("rename"),
    resources = parse("resources"),
    shapes = parse("shapes"),
    smithy = parse("smithy"),
    target = parse("target"),
    traits = parse("traits"),
    type = parse("type"),
    update = parse("update"),
    value = parse("value"),
    version = parse("version"),
    _,

    fn parse(str: []const u8) u64 {
        var code: u64 = 0;
        const len = @min(8, str.len);
        @memcpy(std.mem.asBytes(&code)[0..len], str[0..len]);
        return code;
    }

    pub fn of(str: []const u8) SmithyProperty {
        return @enumFromInt(parse(str));
    }
};

test "SmithyProperty" {
    try testing.expectEqual(.collection_ops, SmithyProperty.of("collectionOperations"));
    try testing.expectEqual(.create, SmithyProperty.of("create"));
    try testing.expectEqual(.delete, SmithyProperty.of("delete"));
    try testing.expectEqual(.errors, SmithyProperty.of("errors"));
    try testing.expectEqual(.identifiers, SmithyProperty.of("identifiers"));
    try testing.expectEqual(.input, SmithyProperty.of("input"));
    try testing.expectEqual(.key, SmithyProperty.of("key"));
    try testing.expectEqual(.list, SmithyProperty.of("list"));
    try testing.expectEqual(.member, SmithyProperty.of("member"));
    try testing.expectEqual(.members, SmithyProperty.of("members"));
    try testing.expectEqual(.metadata, SmithyProperty.of("metadata"));
    try testing.expectEqual(.mixins, SmithyProperty.of("mixins"));
    try testing.expectEqual(.operations, SmithyProperty.of("operations"));
    try testing.expectEqual(.output, SmithyProperty.of("output"));
    try testing.expectEqual(.properties, SmithyProperty.of("properties"));
    try testing.expectEqual(.put, SmithyProperty.of("put"));
    try testing.expectEqual(.read, SmithyProperty.of("read"));
    try testing.expectEqual(.rename, SmithyProperty.of("rename"));
    try testing.expectEqual(.resources, SmithyProperty.of("resources"));
    try testing.expectEqual(.shapes, SmithyProperty.of("shapes"));
    try testing.expectEqual(.smithy, SmithyProperty.of("smithy"));
    try testing.expectEqual(.target, SmithyProperty.of("target"));
    try testing.expectEqual(.traits, SmithyProperty.of("traits"));
    try testing.expectEqual(.type, SmithyProperty.of("type"));
    try testing.expectEqual(.update, SmithyProperty.of("update"));
    try testing.expectEqual(.value, SmithyProperty.of("value"));
    try testing.expectEqual(.version, SmithyProperty.of("version"));
    try testing.expectEqual(
        SmithyProperty.parse("U4K4OW4"),
        @intFromEnum(SmithyProperty.of("U4K4OW4")),
    );
}