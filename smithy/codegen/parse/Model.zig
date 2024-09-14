//! Raw symbols (shapes and metadata) of a Smithy model.
const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const mdl = @import("../model.zig");
const SmithyId = mdl.SmithyId;
const SmithyType = mdl.SmithyType;
const SmithyMeta = mdl.SmithyMeta;
const TaggedValue = mdl.SmithyTaggedValue;

const Self = @This();

allocator: Allocator,
service_id: SmithyId = SmithyId.NULL,
meta: std.AutoHashMapUnmanaged(SmithyId, SmithyMeta) = .{},
shapes: std.AutoHashMapUnmanaged(SmithyId, SmithyType) = .{},
names: std.AutoHashMapUnmanaged(SmithyId, []const u8) = .{},
traits: std.AutoHashMapUnmanaged(SmithyId, []const TaggedValue) = .{},
mixins: std.AutoHashMapUnmanaged(SmithyId, []const SmithyId) = .{},

pub fn init(allocator: Allocator) Self {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Self) void {
    self.meta.deinit(self.allocator);
    self.shapes.deinit(self.allocator);
    self.traits.deinit(self.allocator);
    self.mixins.deinit(self.allocator);
    self.names.deinit(self.allocator);
}

pub fn putMeta(self: *Self, key: SmithyId, value: SmithyMeta) !void {
    try self.meta.put(self.allocator, key, value);
}

pub fn putShape(self: *Self, id: SmithyId, shape: SmithyType) !void {
    try self.shapes.put(self.allocator, id, shape);
}

pub fn putName(self: *Self, id: SmithyId, name: []const u8) !void {
    try self.names.put(self.allocator, id, name);
}

pub fn putMixins(self: *Self, id: SmithyId, mixins: []const SmithyId) !void {
    try self.mixins.put(self.allocator, id, mixins);
}

/// Returns `true` if expanded an existing traits list.
pub fn putTraits(self: *Self, id: SmithyId, traits: []const mdl.SmithyTaggedValue) !bool {
    const result = try self.traits.getOrPut(self.allocator, id);
    if (!result.found_existing) {
        result.value_ptr.* = traits;
        return false;
    }

    const current = result.value_ptr.*;
    const all = try self.allocator.alloc(TaggedValue, current.len + traits.len);
    @memcpy(all[0..current.len], current);
    @memcpy(all[current.len..][0..traits.len], traits);
    self.allocator.free(current);
    result.value_ptr.* = all;
    return true;
}

test "putTraits" {
    const foo = "Foo";
    const bar = "Bar";
    const baz = "Baz";

    var model = Self.init(test_alloc);
    defer model.deinit();

    const traits = try test_alloc.alloc(TaggedValue, 2);
    traits[0] = .{ .id = SmithyId.of("Foo"), .value = foo };
    traits[1] = .{ .id = SmithyId.of("Bar"), .value = bar };
    {
        errdefer test_alloc.free(traits);
        try testing.expectEqual(false, try model.putTraits(SmithyId.of("Traits"), traits));
        try testing.expectEqualDeep(&[_]TaggedValue{
            .{ .id = SmithyId.of("Foo"), .value = foo },
            .{ .id = SmithyId.of("Bar"), .value = bar },
        }, model.traits.get(SmithyId.of("Traits")));

        try testing.expectEqual(true, try model.putTraits(
            SmithyId.of("Traits"),
            &.{.{ .id = SmithyId.of("Baz"), .value = baz }},
        ));
    }
    defer test_alloc.free(model.traits.get(SmithyId.of("Traits")).?);

    try testing.expectEqualDeep(&[_]TaggedValue{
        .{ .id = SmithyId.of("Foo"), .value = foo },
        .{ .id = SmithyId.of("Bar"), .value = bar },
        .{ .id = SmithyId.of("Baz"), .value = baz },
    }, model.traits.get(SmithyId.of("Traits")));
}
