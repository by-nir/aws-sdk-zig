const std = @import("std");
const testing = std.testing;
const test_alloc = testing.allocator;
const identity = @import("identity.zig");
const SmithyId = identity.SmithyId;
const SmithyType = identity.SmithyType;
const TaggedValue = identity.SmithyTaggedValue;

/// Parsed symbols (shapes and metadata) from a Smithy model.
pub const SmithyModel = struct {
    service: SmithyId,
    meta: std.AutoHashMapUnmanaged(SmithyId, SmithyMeta),
    shapes: std.AutoHashMapUnmanaged(SmithyId, SmithyType),
    traits: std.AutoHashMapUnmanaged(SmithyId, []const TaggedValue),
    mixins: std.AutoHashMapUnmanaged(SmithyId, []const SmithyId),

    pub fn getMeta(self: SmithyModel, key: SmithyId) ?SmithyMeta {
        return self.meta.get(key);
    }

    pub fn getShape(self: SmithyModel, id: SmithyId) ?SmithyType {
        return self.shapes.get(id);
    }

    pub fn getMixins(self: SmithyModel, shape_id: SmithyId) ?[]const SmithyId {
        return self.mixins.get(shape_id) orelse null;
    }

    pub fn getTraits(self: SmithyModel, shape_id: SmithyId) ?[]const TaggedValue {
        return self.traits.get(shape_id) orelse null;
    }

    pub fn hasTrait(self: SmithyModel, shape_id: SmithyId, trait_id: SmithyId) bool {
        const traits = self.traits.get(shape_id) orelse return false;
        for (traits) |trait| {
            if (trait.id == trait_id) return true;
        }
        return false;
    }

    pub fn getTrait(self: SmithyModel, shape_id: SmithyId, trait_id: SmithyId, comptime T: type) ?TraitReturn(T) {
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
        .traits = traits,
        .mixins = mixins,
    };

    try testing.expectEqualDeep(
        SmithyMeta{ .integer = 108 },
        symbols.getMeta(shape_id),
    );

    try testing.expectEqual(.blob, symbols.getShape(shape_id));

    try testing.expectEqualDeep(
        &.{ SmithyId.of("test.mixin#Foo"), SmithyId.of("test.mixin#Bar") },
        symbols.getMixins(shape_id),
    );

    try testing.expectEqualDeep(&.{
        TaggedValue{ .id = trait_void, .value = null },
        TaggedValue{ .id = trait_int, .value = &int },
    }, symbols.getTraits(shape_id));
    try testing.expect(symbols.hasTrait(shape_id, trait_void));
    try testing.expectEqual(
        108,
        symbols.getTrait(shape_id, trait_int, u8),
    );
}

/// A service is the entry point of an API that aggregates resources and operations together.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/service-types.html#service)
pub const SmithyService = struct {
    version: []const u8 = &.{},
    operations: []const SmithyId = &.{},
    resources: []const SmithyId = &.{},
    errors: []const SmithyId = &.{},
    rename: []const identity.SmithyRefMapValue = &.{},
};

/// The operation type represents the input, output, and possible errors of an API operation.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/service-types.html#resource)
pub const SmithyResource = struct {
    identifiers: []const identity.SmithyRefMapValue = &.{},
    properties: []const identity.SmithyRefMapValue = &.{},
    create: SmithyId = SmithyId.NULL,
    put: SmithyId = SmithyId.NULL,
    read: SmithyId = SmithyId.NULL,
    update: SmithyId = SmithyId.NULL,
    delete: SmithyId = SmithyId.NULL,
    list: SmithyId = SmithyId.NULL,
    operations: []const SmithyId = &.{},
    collection_ops: []const SmithyId = &.{},
    resources: []const SmithyId = &.{},
};

/// Smithy defines a resource as an entity with an identity that has a set of operations.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/service-types.html#operation)
pub const SmithyOperation = struct {
    input: ?SmithyId = null,
    output: ?SmithyId = null,
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
