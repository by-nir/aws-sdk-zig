const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = std.testing.allocator;
const JsonReader = @import("../utils/JsonReader.zig");
const identity = @import("identity.zig");
const SmithyId = identity.SmithyId;
const TaggedValue = identity.SmithyTaggedValue;

/// Parse the trait’s value from the source JSON AST, which will be used
/// during the source generation.
const SmithyTrait = *const fn (
    arena: Allocator,
    reader: *JsonReader,
) anyerror!*const anyopaque;

pub const TraitsRegistry = []const struct { SmithyId, ?SmithyTrait };

pub const TraitsBag = struct {
    values: []const TaggedValue,

    pub fn has(self: TraitsBag, id: SmithyId) bool {
        for (self.values) |trait| {
            if (trait.id == id) return true;
        }
        return false;
    }

    pub fn TraitReturn(comptime T: type) type {
        return switch (@typeInfo(T)) {
            .Bool, .Int, .Float, .Enum, .Union, .Pointer => T,
            else => *const T,
        };
    }

    pub fn get(self: TraitsBag, comptime T: type, id: SmithyId) ?TraitReturn(T) {
        const trait = self.getOpaque(id) orelse return null;
        const ptr: *const T = @alignCast(@ptrCast(trait));
        return switch (@typeInfo(T)) {
            .Bool, .Int, .Float, .Enum, .Union, .Pointer => ptr.*,
            else => ptr,
        };
    }

    pub fn getOpaque(self: TraitsBag, id: SmithyId) ?*const anyopaque {
        for (self.values) |trait| {
            if (trait.id == id) return trait.value;
        }
        return null;
    }
};

test "TraitsBag" {
    const int: u8 = 108;
    const traits = TraitsBag{ .values = &.{
        .{ .id = SmithyId.of("foo"), .value = null },
        .{ .id = SmithyId.of("bar"), .value = &int },
    } };

    try testing.expect(traits.has(SmithyId.of("foo")));
    try testing.expect(traits.has(SmithyId.of("bar")));
    try testing.expect(!traits.has(SmithyId.of("baz")));
    try testing.expectEqual(
        @intFromPtr(&int),
        @intFromPtr(traits.getOpaque(SmithyId.of("bar")).?),
    );
    try testing.expectEqual(108, traits.get(u8, SmithyId.of("bar")));
}

/// Traits are model components that can be attached to shapes to describe additional
/// information about the shape; shapes provide the structure and layout of an API,
/// while traits provide refinement and style.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/model.html#traits)
pub const TraitsManager = struct {
    traits: std.AutoHashMapUnmanaged(SmithyId, ?SmithyTrait) = .{},

    pub fn deinit(self: *TraitsManager, allocator: Allocator) void {
        self.traits.deinit(allocator);
        self.* = undefined;
    }

    pub fn register(self: *TraitsManager, allocator: Allocator, id: SmithyId, trait: ?SmithyTrait) !void {
        try self.traits.put(allocator, id, trait);
    }

    pub fn registerAll(self: *TraitsManager, allocator: Allocator, traits: TraitsRegistry) !void {
        try self.traits.ensureUnusedCapacity(allocator, @truncate(traits.len));
        for (traits) |t| {
            const id, const trait = t;
            self.traits.putAssumeCapacity(id, trait);
        }
    }

    /// Parse the trait’s value from the source JSON AST, which will be used
    /// during the source generation.
    pub fn parse(self: TraitsManager, trait_id: SmithyId, arena: Allocator, reader: *JsonReader) !?*const anyopaque {
        const trait = self.traits.get(trait_id) orelse return error.UnknownTrait;
        if (trait) |parseFn| {
            // Parse trait’s value
            return parseFn(arena, reader);
        } else {
            // Annotation trait – skip the empty `{}`
            try reader.skipValueOrScope();
            return null;
        }
    }
};

test "TraitManager" {
    const SkipTwoTrait = struct {
        fn parse(arena: Allocator, reader: *JsonReader) !*const anyopaque {
            for (0..2) |_| try reader.skipValueOrScope();
            const dupe = try arena.dupe(u8, try reader.nextString());
            return dupe.ptr;
        }

        pub fn translate(value: ?*const anyopaque) []const u8 {
            const ptr = @as([*]const u8, @ptrCast(value));
            return ptr[0..3];
        }
    };

    var manager = TraitsManager{};
    defer manager.deinit(test_alloc);

    const test_id = SmithyId.of("test");
    try manager.register(test_alloc, test_id, SkipTwoTrait.parse);

    var reader = try JsonReader.initFixed(test_alloc,
        \\["foo", "bar", "baz", "qux"]
    );
    defer reader.deinit();

    _ = try reader.next();
    const value = SkipTwoTrait.translate(
        try manager.parse(test_id, test_alloc, &reader),
    );
    defer test_alloc.free(value);
    try testing.expectEqualStrings("baz", value);
}
