const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = std.testing.allocator;
const syb = @import("symbols.zig");
const SmithyId = syb.SmithyId;
const TaggedValue = syb.SmithyTaggedValue;
const JsonReader = @import("../utils/JsonReader.zig");

/// Parse the trait’s value from the source JSON AST, which will be used
/// during the source generation.
const TraitParser = *const fn (
    arena: Allocator,
    reader: *JsonReader,
) anyerror!*const anyopaque;

pub const TraitsRegistry = []const struct { SmithyId, ?TraitParser };

/// Traits are model components that can be attached to shapes to describe additional
/// information about the shape; shapes provide the structure and layout of an API,
/// while traits provide refinement and style.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/model.html#traits)
pub const TraitsManager = struct {
    traits: std.AutoHashMapUnmanaged(SmithyId, ?TraitParser) = .{},

    pub fn deinit(self: *TraitsManager, allocator: Allocator) void {
        self.traits.deinit(allocator);
        self.* = undefined;
    }

    pub fn register(self: *TraitsManager, allocator: Allocator, id: SmithyId, parser: ?TraitParser) !void {
        try self.traits.put(allocator, id, parser);
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

pub const TraitsProvider = struct {
    values: []const TaggedValue,

    pub fn has(self: TraitsProvider, id: SmithyId) bool {
        for (self.values) |trait| {
            if (trait.id == id) return true;
        }
        return false;
    }

    pub fn TraitReturn(comptime T: type) type {
        return switch (@typeInfo(T)) {
            .bool, .int, .float, .@"enum", .@"union", .pointer => T,
            else => *const T,
        };
    }

    pub fn get(self: TraitsProvider, comptime T: type, id: SmithyId) ?TraitReturn(T) {
        const trait = self.getOpaque(id) orelse return null;
        const ptr: *const T = @alignCast(@ptrCast(trait));
        return switch (@typeInfo(T)) {
            .bool, .int, .float, .@"enum", .@"union", .pointer => ptr.*,
            else => ptr,
        };
    }

    pub fn getOpaque(self: TraitsProvider, id: SmithyId) ?*const anyopaque {
        for (self.values) |trait| {
            if (trait.id == id) return trait.value;
        }
        return null;
    }
};

test "TraitsProvider" {
    const int: u8 = 108;
    const traits = TraitsProvider{ .values = &.{
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

pub fn StringTrait(trait_id: []const u8) type {
    return struct {
        pub const id = SmithyId.of(trait_id);

        pub fn parse(arena: Allocator, reader: *JsonReader) !*const anyopaque {
            const value = try arena.create([]const u8);
            value.* = try reader.nextStringAlloc(arena);
            return @ptrCast(value);
        }

        pub fn get(symbols: *syb.SymbolsProvider, shape_id: SmithyId) ?[]const u8 {
            return symbols.getTrait([]const u8, shape_id, id);
        }
    };
}

test "StringTrait" {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    const TestTrait = StringTrait("smithy.api#test");

    var reader = try JsonReader.initFixed(arena_alloc, "\"Foo Bar\"");
    const val: *const []const u8 = @alignCast(@ptrCast(TestTrait.parse(arena_alloc, &reader) catch |e| {
        reader.deinit();
        return e;
    }));
    reader.deinit();
    try testing.expectEqualStrings("Foo Bar", val.*);
}
