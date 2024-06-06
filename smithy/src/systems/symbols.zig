const std = @import("std");
const testing = std.testing;
const test_alloc = testing.allocator;
const prelude = @import("../prelude.zig");
const TraitsProvider = @import("traits.zig").TraitsProvider;

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
    operation: *const SmithyOperation,
    /// Smithy defines a resource as an entity with an identity that has a set of operations.
    resource: *const SmithyResource,
    /// A service is the entry point of an API that aggregates resources and operations together.
    service: *const SmithyService,
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

/// Parsed symbols (shapes and metadata) from a Smithy model.
pub const SmithyModel = struct {
    service: SmithyId = SmithyId.NULL,
    meta: std.AutoHashMapUnmanaged(SmithyId, SmithyMeta) = .{},
    shapes: std.AutoHashMapUnmanaged(SmithyId, SmithyType) = .{},
    names: std.AutoHashMapUnmanaged(SmithyId, []const u8) = .{},
    traits: std.AutoHashMapUnmanaged(SmithyId, []const SmithyTaggedValue) = .{},
    mixins: std.AutoHashMapUnmanaged(SmithyId, []const SmithyId) = .{},

    pub fn deinit(self: *SmithyModel, allocator: std.mem.Allocator) void {
        self.meta.deinit(allocator);
        self.shapes.deinit(allocator);
        self.traits.deinit(allocator);
        self.mixins.deinit(allocator);
        self.names.deinit(allocator);
    }

    pub fn getMeta(self: SmithyModel, key: SmithyId) ?SmithyMeta {
        return self.meta.get(key);
    }

    pub fn getShape(self: SmithyModel, id: SmithyId) ?SmithyType {
        return self.shapes.get(id);
    }

    pub fn tryGetShape(self: SmithyModel, id: SmithyId) !SmithyType {
        return self.shapes.get(id) orelse error.ShapeNotFound;
    }

    pub fn getName(self: SmithyModel, id: SmithyId) ?[]const u8 {
        return self.names.get(id);
    }

    pub fn tryGetName(self: SmithyModel, id: SmithyId) ![]const u8 {
        return self.names.get(id) orelse error.NameNotFound;
    }

    pub fn getMixins(self: SmithyModel, shape_id: SmithyId) ?[]const SmithyId {
        return self.mixins.get(shape_id) orelse null;
    }

    pub fn getTraits(self: SmithyModel, shape_id: SmithyId) ?TraitsProvider {
        const traits = self.traits.get(shape_id) orelse return null;
        return TraitsProvider{ .values = traits };
    }

    pub fn hasTrait(self: SmithyModel, shape_id: SmithyId, trait_id: SmithyId) bool {
        return if (self.getTraits(shape_id)) |t| t.has(trait_id) else false;
    }

    pub fn getTraitOpaque(self: SmithyModel, shape_id: SmithyId, trait_id: SmithyId) ?*const anyopaque {
        return if (self.getTraits(shape_id)) |t| t.getOpaque(trait_id) else null;
    }

    pub fn getTrait(
        self: SmithyModel,
        comptime T: type,
        shape_id: SmithyId,
        trait_id: SmithyId,
    ) ?TraitsProvider.TraitReturn(T) {
        return if (self.getTraits(shape_id)) |t| t.get(T, trait_id) else null;
    }
};

test "SmithyModel" {
    const int: u8 = 108;
    const shape_id = SmithyId.of("test.simple#Blob");
    const trait_void = SmithyId.of("test.trait#Void");
    const trait_int = SmithyId.of("test.trait#Int");

    var meta: std.AutoHashMapUnmanaged(SmithyId, SmithyMeta) = .{};
    defer meta.deinit(test_alloc);
    try meta.put(test_alloc, shape_id, .{ .integer = 108 });

    var shapes: std.AutoHashMapUnmanaged(SmithyId, SmithyType) = .{};
    defer shapes.deinit(test_alloc);
    try shapes.put(test_alloc, shape_id, .blob);

    var names: std.AutoHashMapUnmanaged(SmithyId, []const u8) = .{};
    defer names.deinit(test_alloc);
    try names.put(test_alloc, shape_id, "Foo");

    var traits: std.AutoHashMapUnmanaged(SmithyId, []const SmithyTaggedValue) = .{};
    defer traits.deinit(test_alloc);
    try traits.put(test_alloc, shape_id, &.{
        .{ .id = trait_void, .value = null },
        .{ .id = trait_int, .value = &int },
    });

    var mixins: std.AutoHashMapUnmanaged(SmithyId, []const SmithyId) = .{};
    defer mixins.deinit(test_alloc);
    try mixins.put(test_alloc, shape_id, &.{
        SmithyId.of("test.mixin#Foo"),
        SmithyId.of("test.mixin#Bar"),
    });

    const symbols = SmithyModel{
        .service = SmithyId.NULL,
        .meta = meta,
        .shapes = shapes,
        .names = names,
        .traits = traits,
        .mixins = mixins,
    };

    try testing.expectEqualDeep(
        SmithyMeta{ .integer = 108 },
        symbols.getMeta(shape_id),
    );

    try testing.expectEqual(.blob, symbols.getShape(shape_id));
    try testing.expectEqual(.blob, symbols.tryGetShape(shape_id));
    try testing.expectError(
        error.ShapeNotFound,
        symbols.tryGetShape(SmithyId.of("test#undefined")),
    );

    try testing.expectEqualStrings("Foo", symbols.getName(shape_id).?);
    try testing.expectError(
        error.NameNotFound,
        symbols.tryGetName(SmithyId.of("test#undefined")),
    );

    try testing.expectEqualDeep(
        &.{ SmithyId.of("test.mixin#Foo"), SmithyId.of("test.mixin#Bar") },
        symbols.getMixins(shape_id),
    );

    try testing.expectEqualDeep(TraitsProvider{ .values = &.{
        SmithyTaggedValue{ .id = trait_void, .value = null },
        SmithyTaggedValue{ .id = trait_int, .value = &int },
    } }, symbols.getTraits(shape_id));
}

/// A service is the entry point of an API that aggregates resources and operations together.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/service-types.html#service)
pub const SmithyService = struct {
    /// Defines the optional version of the service.
    version: ?[]const u8 = null,
    /// Binds a set of operation shapes to the service.
    operations: []const SmithyId = &.{},
    /// Binds a set of resource shapes to the service.
    resources: []const SmithyId = &.{},
    /// Defines a list of common errors that every operation bound within the closure of the service can return.
    errors: []const SmithyId = &.{},
    /// Disambiguates shape name conflicts in the
    /// [service closure](https://smithy.io/2.0/spec/service-types.html#service-closure).
    rename: []const SmithyRefMapValue = &.{},
};

/// The operation type represents the input, output, and possible errors of an API operation.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/service-types.html#resource)
pub const SmithyResource = struct {
    /// Defines a map of identifier string names to Shape IDs used to identify the resource.
    identifiers: []const SmithyRefMapValue = &.{},
    /// Defines a map of property string names to Shape IDs that enumerate the properties of the resource.
    properties: []const SmithyRefMapValue = &.{},
    /// Defines the lifecycle operation used to create a resource using one or more identifiers created by the service.
    create: ?SmithyId = null,
    /// Defines an idempotent lifecycle operation used to create a resource using identifiers provided by the client.
    put: ?SmithyId = null,
    /// Defines the lifecycle operation used to retrieve the resource.
    read: ?SmithyId = null,
    /// Defines the lifecycle operation used to update the resource.
    update: ?SmithyId = null,
    /// Defines the lifecycle operation used to delete the resource.
    delete: ?SmithyId = null,
    /// Defines the lifecycle operation used to list resources of this type.
    list: ?SmithyId = null,
    /// Binds a list of non-lifecycle instance operations to the resource.
    operations: []const SmithyId = &.{},
    /// Binds a list of non-lifecycle collection operations to the resource.
    collection_ops: []const SmithyId = &.{},
    /// Binds a list of resources to this resource as a child resource, forming a containment relationship.
    resources: []const SmithyId = &.{},
};

/// Smithy defines a resource as an entity with an identity that has a set of operations.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/service-types.html#operation)
pub const SmithyOperation = struct {
    /// The input of the operation defined using a shape ID that MUST target a structure.
    input: ?SmithyId = null,
    /// The output of the operation defined using a shape ID that MUST target a structure.
    output: ?SmithyId = null,
    /// The errors that an operation can return.
    errors: []const SmithyId = &.{},
};

/// Node values are JSON-like values used to define metadata and the value of an applied trait.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/model.html#node-values)
pub const SmithyMeta = union(enum) {
    /// The lack of a value.
    null,
    /// A UTF-8 string.
    string: []const u8,
    /// A double precision integer number.
    ///
    /// _Note: The original spec does not distinguish between number types._
    integer: i64,
    /// A double precision floating point number.
    ///
    /// _Note: The original spec does not distinguish between number types._
    float: f64,
    /// A Boolean, true or false value.
    boolean: bool,
    /// An array of heterogeneous node values.
    list: []const SmithyMeta,
    /// A object mapping string keys to heterogeneous node values.
    map: []const Pair,

    /// A key-value pair in a Map node.
    pub const Pair = struct {
        key: SmithyId,
        value: SmithyMeta,
    };
};
