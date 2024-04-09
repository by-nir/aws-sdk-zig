const std = @import("std");
const testing = std.testing;
const test_alloc = testing.allocator;
const prelude = @import("../prelude.zig");

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
    /// Type name or absalute shape id.
    pub fn of(shape_id: []const u8) SmithyId {
        return switch (hash32(shape_id)) {
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
            else => |h| @enumFromInt(h),
        };
    }

    /// `smithy.example.foo#ExampleShapeName` + `memberName`
    pub fn compose(shape: []const u8, member: []const u8) SmithyId {
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
};

test "SmithyId" {
    try testing.expectEqual(.blob, SmithyId.of("blob"));
    try testing.expectEqual(.blob, SmithyId.of("smithy.api#Blob"));
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

/// [Simple](https://smithy.io/2.0/spec/simple-types.html#simple-types) or
/// [Aggregate](https://smithy.io/2.0/spec/aggregate-types.html#aggregate-types) shape.
pub const SmithyType = union(enum) {
    /// A shape that is not a member of the prelude.
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
    //

    /// Uninterpreted binary data.
    blob,
    /// Boolean value type.
    boolean,
    /// UTF-8 encoded string.
    string,
    /// A string with a fixed set of values.
    @"enum": []const SmithyId,
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
    //

    /// Ordered collection of homogeneous values.
    list: SmithyId,
    /// Map data structure that maps string keys to homogeneous values.
    map: [2]SmithyId,
    /// Fixed set of named heterogeneous members.
    structure: []const SmithyId,
    /// Tagged union data structure that can take on one of several different, but fixed, types.
    @"union": []const SmithyId,
};

/// Parsed symbols (shapes and metadata) from a Smithy model.
pub const Symbols = struct {
    pub const TraitValue = struct {
        id: SmithyId,
        value: ?*const anyopaque,
    };

    shapes: std.AutoHashMapUnmanaged(SmithyId, SmithyType),
    traits: std.AutoHashMapUnmanaged(SmithyId, []const TraitValue),

    pub fn getShape(self: Symbols, id: SmithyId) ?SmithyType {
        return self.shapes.get(id);
    }

    pub fn getTraits(self: Symbols, shape_id: SmithyId) ?[]const TraitValue {
        return self.traits.get(shape_id) orelse null;
    }

    pub fn hasTrait(self: Symbols, shape_id: SmithyId, trait_id: SmithyId) bool {
        const traits = self.traits.get(shape_id) orelse return false;
        for (traits) |trait| {
            if (trait.id == trait_id) return true;
        }
        return false;
    }

    pub fn getTrait(self: Symbols, shape_id: SmithyId, trait_id: SmithyId, comptime T: type) ?TraitReturn(T) {
        const traits = self.traits.get(shape_id) orelse return null;
        for (traits) |trait| {
            if (trait.id != trait_id) continue;
            const ptr: *const T = @alignCast(@ptrCast(trait.value));
            return switch (@typeInfo(T)) {
                .Bool, .Int, .Float, .Enum, .Union, .Pointer => ptr.*,
                else => ptr,
            };
        }
        return null;
    }

    fn TraitReturn(comptime T: type) type {
        return switch (@typeInfo(T)) {
            .Bool, .Int, .Float, .Enum, .Union, .Pointer => T,
            else => *const T,
        };
    }
};

test "Symbols" {
    const int: u8 = 108;
    const shape_id = SmithyId.of("test.simple#Blob");
    const trait_void = SmithyId.of("test.trait#Void");
    const trait_int = SmithyId.of("test.trait#Int");

    var shapes: std.AutoHashMapUnmanaged(SmithyId, SmithyType) = .{};
    defer shapes.deinit(test_alloc);
    try shapes.put(test_alloc, shape_id, .blob);

    var traits: std.AutoHashMapUnmanaged(SmithyId, []const Symbols.TraitValue) = .{};
    defer traits.deinit(test_alloc);
    try traits.put(test_alloc, shape_id, &.{
        .{ .id = trait_void, .value = null },
        .{ .id = trait_int, .value = &int },
    });

    const symbols = Symbols{ .shapes = shapes, .traits = traits };

    try testing.expectEqual(.blob, symbols.getShape(shape_id));
    try testing.expectEqualDeep(&.{
        Symbols.TraitValue{ .id = trait_void, .value = null },
        Symbols.TraitValue{ .id = trait_int, .value = &int },
    }, symbols.getTraits(shape_id).?);

    try testing.expect(symbols.hasTrait(shape_id, trait_void));
    try testing.expectEqual(108, symbols.getTrait(shape_id, trait_int, u8));
}

/// All known Smithy properties.
pub const SmithyProperty = enum(u64) {
    // If adding more properties, make sure their first 8 characters are unique.
    collection_operations = parse("collectionOperations"),
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
    try testing.expectEqual(.collection_operations, SmithyProperty.of("collectionOperations"));
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
    try testing.expectEqual(SmithyProperty.parse("U4K4OW4"), @intFromEnum(SmithyProperty.of("U4K4OW4")));
}
