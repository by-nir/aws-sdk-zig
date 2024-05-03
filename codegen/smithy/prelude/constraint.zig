//! Constraint traits are used to constrain the values that can be provided for
//! a shape. Constraint traits are for validation only and SHOULD NOT impact the
//! types signatures of generated code.
//!
//! [Smithy Spec](https://smithy.io/2.0/spec/constraint-traits.html)

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const SmithyId = @import("../symbols/identity.zig").SmithyId;
const TraitsList = @import("../symbols/traits.zig").TraitsRegistry;
const SmithyModel = @import("../symbols/shapes.zig").SmithyModel;
const JsonReader = @import("../utils/JsonReader.zig");

// TODO: Remainig traits
pub const traits: TraitsList = &.{
    .{ id_ref_id, null },
    // smithy.api#length
    // smithy.api#pattern
    .{ private_id, null },
    // smithy.api#range
    // smithy.api#uniqueItems
    .{ Enum.id, Enum.parse },
};

pub const id_ref_id = SmithyId.of("smithy.api#idRef");
pub const private_id = SmithyId.of("smithy.api#private");

/// **[DEPRECATED]**
/// Constrains the acceptable values of a string to a fixed set.
/// Still used by most AWS services that declare enums.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/constraint-traits.html#enum-trait)
pub const Enum = struct {
    pub const id = SmithyId.of("smithy.api#enum");

    pub const Sentinel = [*:Member.empty]const Member;
    pub const Member = struct {
        /// Defines the enum value that is sent over the wire.
        value: []const u8,
        /// Defines a constant name that can be used in programming languages to
        /// reference an enum value.
        name: ?[]const u8 = null,
        /// Defines documentation about the enum value in the `CommonMark` format.
        documentation: ?[]const u8 = null,
        /// Attaches a list of tags that allow the enum value to be categorized
        /// and grouped.
        tags: ?[]const []const u8 = null,
        /// Whether the enum value should be considered deprecated for consumers
        /// of the Smithy model.
        deprecated: bool = false,

        const empty = Member{ .value = "" };
    };

    const Context = struct {
        arena: Allocator,
        member: *Member,
    };

    pub fn parse(arena: Allocator, reader: *JsonReader) !*const anyopaque {
        var list = std.ArrayList(Member).init(arena);
        errdefer list.deinit();

        try reader.nextArrayBegin();
        while (try reader.next() == .object_begin) {
            var member = Member.empty;
            try reader.nextScope(*JsonReader, Context, .current, parseMember, reader, .{
                .arena = arena,
                .member = &member,
            });
            try list.append(member);
        }

        const slice = try list.toOwnedSliceSentinel(Member.empty);
        return slice.ptr;
    }

    fn parseMember(reader: *JsonReader, prop: []const u8, ctx: Context) !void {
        if (std.mem.eql(u8, prop, "value")) {
            ctx.member.value = try ctx.arena.dupe(u8, try reader.nextString());
        } else if (std.mem.eql(u8, prop, "name")) {
            ctx.member.name = try ctx.arena.dupe(u8, try reader.nextString());
        } else if (std.mem.eql(u8, prop, "documentation")) {
            ctx.member.documentation = try ctx.arena.dupe(u8, try reader.nextString());
        } else if (std.mem.eql(u8, prop, "tags")) {
            var list = std.ArrayList([]const u8).init(ctx.arena);
            errdefer list.deinit();
            try reader.nextArrayBegin();
            while (try reader.peek() != .array_end) {
                try list.append(try ctx.arena.dupe(u8, try reader.nextString()));
            }
            try reader.nextArrayEnd();
            ctx.member.tags = try list.toOwnedSlice();
        } else if (std.mem.eql(u8, prop, "deprecated")) {
            ctx.member.deprecated = try reader.nextBoolean();
        } else {
            try reader.skipValueOrScope();
        }
    }

    pub fn get(model: *const SmithyModel, shape_id: SmithyId) ?[]const Member {
        const trait = model.getTraitOpaque(shape_id, id);
        return if (trait) |ptr| cast(ptr) else null;
    }

    fn cast(ptr: *const anyopaque) []const Member {
        const pairs: Sentinel = @alignCast(@ptrCast(ptr));
        var i: usize = 0;
        while (true) : (i += 1) {
            const pair = pairs[i];
            if (pair.value.len == 0) return pairs[0..i];
        }
        unreachable;
    }
};

test "Enum" {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const allocator = arena.allocator();
    defer arena.deinit();

    var reader = try JsonReader.initFixed(allocator,
        \\[
        \\  {
        \\    "value": "FooBar",
        \\    "name": "FOO_BAR"
        \\  },
        \\  {
        \\    "value": "BazQux",
        \\    "name": "BAZ_QUX",
        \\    "documentation": "foo",
        \\    "tags": [ "bar", "baz" ],
        \\    "deprecated": true
        \\  }
        \\]
    );
    errdefer reader.deinit();

    const members = Enum.cast(try Enum.parse(allocator, &reader));
    reader.deinit();
    try testing.expectEqualDeep(Enum.Member{
        .value = "FooBar",
        .name = "FOO_BAR",
    }, members[0]);
    try testing.expectEqualDeep(Enum.Member{
        .value = "BazQux",
        .name = "BAZ_QUX",
        .documentation = "foo",
        .tags = &.{ "bar", "baz" },
        .deprecated = true,
    }, members[1]);
}
