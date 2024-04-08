const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = std.testing.allocator;
const SmithyId = @import("identity.zig").SmithyId;
const JsonReader = @import("JsonReader.zig");

/// Traits are model components that can be attached to shapes to describe additional
/// information about the shape; shapes provide the structure and layout of an API,
/// while traits provide refinement and style.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/model.html#traits)
pub const Trait = struct {
    ctx: *const anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        parse: ?*const fn (ctx: *const anyopaque, allocator: Allocator, reader: *JsonReader) anyerror!*const anyopaque,
    };

    /// Parse the trait’s value from the source JSON AST, which will be used
    /// during the source generation.
    pub fn parse(self: Trait, allocator: Allocator, reader: *JsonReader) !?*const anyopaque {
        if (self.vtable.parse) |parseFn| {
            // Parse trait’s value
            return parseFn(self.ctx, allocator, reader);
        } else {
            // Tag trait – skip the empty `{}`
            try reader.skipValueOrScope();
            return null;
        }
    }
};

pub const TraitManager = struct {
    traits: std.AutoHashMapUnmanaged(SmithyId, Trait) = .{},

    pub fn deinit(self: *TraitManager, allocator: Allocator) void {
        self.traits.deinit(allocator);
        self.* = undefined;
    }

    pub fn register(self: *TraitManager, allocator: Allocator, id: SmithyId, trait: Trait) !void {
        try self.traits.put(allocator, id, trait);
    }

    pub fn registerAll(self: *TraitManager, allocator: Allocator, traits: []const struct { SmithyId, Trait }) !void {
        try self.traits.ensureUnusedCapacity(allocator, traits.len);
        for (traits) |t| {
            const id, const trait = t;
            try self.traits.putAssumeCapacity(allocator, id, trait);
        }
    }

    pub fn parse(self: TraitManager, trait_id: SmithyId, allocator: Allocator, reader: *JsonReader) !?*const anyopaque {
        const trait = self.traits.get(trait_id) orelse return error.UnknownTrait;
        return trait.parse(allocator, reader);
    }
};

test "TraitManager" {
    const TestTrait = struct {
        skip: usize,

        pub fn trait(self: *const @This()) Trait {
            return Trait{ .ctx = self, .vtable = &.{
                .parse = parse,
            } };
        }

        fn parse(ctx: *const anyopaque, allocator: Allocator, reader: *JsonReader) !*const anyopaque {
            const self: *const @This() = @alignCast(@ptrCast(ctx));
            for (0..self.skip) |_| try reader.skipValueOrScope();
            const dupe = try allocator.dupe(u8, try reader.nextString());
            return dupe.ptr;
        }

        pub fn translate(value: ?*const anyopaque) []const u8 {
            const ptr = @as([*]const u8, @ptrCast(value));
            return ptr[0..3];
        }
    };

    var manager = TraitManager{};
    defer manager.deinit(test_alloc);

    const test_id = SmithyId.of("test");
    const test_trait = TestTrait{ .skip = 2 };
    try manager.register(test_alloc, test_id, test_trait.trait());

    const test_json =
        \\["foo", "bar", "baz", "qux"]
    ;
    var stream = std.io.fixedBufferStream(test_json);
    var reader = JsonReader.init(test_alloc, stream.reader().any());
    defer reader.deinit();

    _ = try reader.next();
    const value = TestTrait.translate(
        try manager.parse(test_id, test_alloc, &reader),
    );
    defer test_alloc.free(value);
    try testing.expectEqualStrings("baz", value);
}
