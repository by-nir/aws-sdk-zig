const std = @import("std");
const testing = std.testing;
const test_alloc = testing.allocator;
const identity = @import("identity.zig");
const SmithyId = identity.SmithyId;
const SmithyType = identity.SmithyType;
const TaggedValue = identity.SmithyTaggedValue;
const TraitsBag = @import("traits.zig").TraitsBag;

/// Parsed symbols (shapes and metadata) from a Smithy model.
pub const SmithyModel = struct {
    service: SmithyId,
    meta: std.AutoHashMapUnmanaged(SmithyId, SmithyMeta),
    shapes: std.AutoHashMapUnmanaged(SmithyId, SmithyType),
    names: std.AutoHashMapUnmanaged(SmithyId, []const u8),
    traits: std.AutoHashMapUnmanaged(SmithyId, []const TaggedValue),
    mixins: std.AutoHashMapUnmanaged(SmithyId, []const SmithyId),

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

    pub fn getTraits(self: SmithyModel, shape_id: SmithyId) ?TraitsBag {
        const traits = self.traits.get(shape_id) orelse return null;
        return TraitsBag{ .values = traits };
    }

    pub fn hasTrait(self: SmithyModel, shape_id: SmithyId, trait_id: SmithyId) bool {
        return if (self.getTraits(shape_id)) |t| t.has(trait_id) else false;
    }

    pub fn getTraitOpaque(self: SmithyModel, shape_id: SmithyId, trait_id: SmithyId) ?*const anyopaque {
        return if (self.getTraits(shape_id)) |t| t.getOpaque(trait_id) else null;
    }

    pub fn getTrait(
        self: SmithyModel,
        shape_id: SmithyId,
        trait_id: SmithyId,
        comptime T: type,
    ) ?TraitsBag.TraitReturn(T) {
        return if (self.getTraits(shape_id)) |t| t.get(trait_id, T) else null;
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

    var traits: std.AutoHashMapUnmanaged(SmithyId, []const TaggedValue) = .{};
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

    try testing.expectEqualDeep(TraitsBag{ .values = &.{
        TaggedValue{ .id = trait_void, .value = null },
        TaggedValue{ .id = trait_int, .value = &int },
    } }, symbols.getTraits(shape_id));
}

/// A service is the entry point of an API that aggregates resources and operations together.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/service-types.html#service)
pub const SmithyService = struct {
    /// Defines the optional version of the service.
    version: []const u8 = &.{},
    /// Binds a set of operation shapes to the service.
    operations: []const SmithyId = &.{},
    /// Binds a set of resource shapes to the service.
    resources: []const SmithyId = &.{},
    /// Defines a list of common errors that every operation bound within the closure of the service can return.
    errors: []const SmithyId = &.{},
    /// Disambiguates shape name conflicts in the
    /// [service closure](https://smithy.io/2.0/spec/service-types.html#service-closure).
    rename: []const identity.SmithyRefMapValue = &.{},
};

/// The operation type represents the input, output, and possible errors of an API operation.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/service-types.html#resource)
pub const SmithyResource = struct {
    /// Defines a map of identifier string names to Shape IDs used to identify the resource.
    identifiers: []const identity.SmithyRefMapValue = &.{},
    /// Defines a map of property string names to Shape IDs that enumerate the properties of the resource.
    properties: []const identity.SmithyRefMapValue = &.{},
    /// Defines the lifecycle operation used to create a resource using one or more identifiers created by the service.
    create: SmithyId = SmithyId.NULL,
    /// Defines an idempotent lifecycle operation used to create a resource using identifiers provided by the client.
    put: SmithyId = SmithyId.NULL,
    /// Defines the lifecycle operation used to retrieve the resource.
    read: SmithyId = SmithyId.NULL,
    /// Defines the lifecycle operation used to update the resource.
    update: SmithyId = SmithyId.NULL,
    /// Defines the lifecycle operation used to delete the resource.
    delete: SmithyId = SmithyId.NULL,
    /// Defines the lifecycle operation used to list resources of this type.
    list: SmithyId = SmithyId.NULL,
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
