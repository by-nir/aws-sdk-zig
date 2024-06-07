//! Raw symbols (shapes and metadata) of a Smithy model.
const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = std.testing.allocator;
const syb = @import("../systems/symbols.zig");
const SmithyId = syb.SmithyId;
const SmithyMeta = syb.SmithyMeta;
const SmithyType = syb.SmithyType;
const SmithyTaggedValue = syb.SmithyTaggedValue;
const TraitsProvider = @import("../systems/traits.zig").TraitsProvider;

const Self = @This();

allocator: Allocator,
service_id: SmithyId = SmithyId.NULL,
meta: std.AutoHashMapUnmanaged(SmithyId, SmithyMeta) = .{},
shapes: std.AutoHashMapUnmanaged(SmithyId, SmithyType) = .{},
names: std.AutoHashMapUnmanaged(SmithyId, []const u8) = .{},
traits: std.AutoHashMapUnmanaged(SmithyId, []const SmithyTaggedValue) = .{},
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

pub fn consume(self: *Self, arena: Allocator) !syb.SymbolsProvider {
    var dupe_meta = try self.meta.clone(arena);
    errdefer dupe_meta.deinit(arena);

    var dupe_shapes = try self.shapes.clone(arena);
    errdefer dupe_shapes.deinit(arena);

    var dupe_names = try self.names.clone(arena);
    errdefer dupe_names.deinit(arena);

    var dupe_traits = try self.traits.clone(arena);
    errdefer dupe_traits.deinit(arena);

    const dupe_mixins = try self.mixins.clone(arena);

    defer self.deinit();
    return .{
        .arena = arena,
        .service_id = self.service_id,
        .model_meta = dupe_meta,
        .model_shapes = dupe_shapes,
        .model_names = dupe_names,
        .model_traits = dupe_traits,
        .model_mixins = dupe_mixins,
    };
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

/// Returns `true` if expanded an existing traits list.
pub fn putTraits(self: *Self, id: SmithyId, traits: []const syb.SmithyTaggedValue) !bool {
    const result = try self.traits.getOrPut(self.allocator, id);
    if (!result.found_existing) {
        result.value_ptr.* = traits;
        return false;
    }

    const current = result.value_ptr.*;
    const all = try self.allocator.alloc(SmithyTaggedValue, current.len + traits.len);
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

    const traits = try test_alloc.alloc(SmithyTaggedValue, 2);
    traits[0] = .{ .id = SmithyId.of("Foo"), .value = foo };
    traits[1] = .{ .id = SmithyId.of("Bar"), .value = bar };
    {
        errdefer test_alloc.free(traits);
        try testing.expectEqual(false, try model.putTraits(SmithyId.of("Traits"), traits));
        try testing.expectEqualDeep(&[_]SmithyTaggedValue{
            .{ .id = SmithyId.of("Foo"), .value = foo },
            .{ .id = SmithyId.of("Bar"), .value = bar },
        }, model.traits.get(SmithyId.of("Traits")));

        try testing.expectEqual(true, try model.putTraits(
            SmithyId.of("Traits"),
            &.{.{ .id = SmithyId.of("Baz"), .value = baz }},
        ));
    }
    defer test_alloc.free(model.traits.get(SmithyId.of("Traits")).?);

    try testing.expectEqualDeep(&[_]SmithyTaggedValue{
        .{ .id = SmithyId.of("Foo"), .value = foo },
        .{ .id = SmithyId.of("Bar"), .value = bar },
        .{ .id = SmithyId.of("Baz"), .value = baz },
    }, model.traits.get(SmithyId.of("Traits")));
}

pub fn putMixins(self: *Self, id: SmithyId, mixins: []const SmithyId) !void {
    try self.mixins.put(self.allocator, id, mixins);
}

pub fn expectMeta(self: Self, id: SmithyId, expected: SmithyMeta) !void {
    try testing.expectEqualDeep(expected, self.meta.get(id).?);
}

pub fn expectShape(self: Self, id: SmithyId, expected: SmithyType) !void {
    try testing.expectEqualDeep(expected, self.shapes.get(id).?);
}

pub fn expectName(self: Self, id: SmithyId, expected: []const u8) !void {
    try testing.expectEqualStrings(expected, self.names.get(id).?);
}

pub fn expectHasTrait(self: Self, shape_id: SmithyId, trait_id: SmithyId) !void {
    const values = self.traits.get(shape_id) orelse return error.TraitsNotFound;
    const provider = TraitsProvider{ .values = values };
    try testing.expect(provider.has(trait_id));
}

pub fn expectTrait(self: Self, shape_id: SmithyId, trait_id: SmithyId, comptime T: type, expected: T) !void {
    const values = self.traits.get(shape_id) orelse return error.TraitsNotFound;
    const provider = TraitsProvider{ .values = values };
    const actual = provider.get(T, trait_id) orelse return error.ValueNotFound;
    try testing.expectEqualDeep(expected, actual);
}

pub fn expectMixins(self: Self, id: SmithyId, expected: []const SmithyId) !void {
    try testing.expectEqualDeep(expected, self.mixins.get(id));
}
