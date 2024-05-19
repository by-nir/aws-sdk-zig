//! Documentation traits describe shapes in the model in a way that does not
//! materially affect the semantics of the model.
//!
//! [Smithy Spec](https://smithy.io/2.0/spec/documentation-traits.html)

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const TraitsList = @import("../symbols/traits.zig").TraitsRegistry;
const SmithyId = @import("../symbols/identity.zig").SmithyId;
const SmithyModel = @import("../symbols/shapes.zig").SmithyModel;
const JsonReader = @import("../utils/JsonReader.zig");

// TODO: Remainig traits
pub const traits: TraitsList = &.{
    // smithy.api#deprecated
    .{ Documentation.id, Documentation.parse },
    // smithy.api#examples
    // smithy.api#externalDocumentation
    // smithy.api#internal
    // smithy.api#recommended
    // smithy.api#sensitive
    // smithy.api#since
    // smithy.api#tags
    .{ Title.id, Title.parse },
    // smithy.api#unstable
};

/// Adds documentation to a shape or member using the [CommonMark](https://spec.commonmark.org) format.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/documentation-traits.html#documentation-trait)
pub const Documentation = struct {
    pub const id = SmithyId.of("smithy.api#documentation");

    pub fn parse(arena: Allocator, reader: *JsonReader) !*const anyopaque {
        return parseString(arena, reader);
    }

    pub fn get(model: *const SmithyModel, shape_id: SmithyId) ?[]const u8 {
        return model.getTrait([]const u8, shape_id, id);
    }
};

/// Defines a proper name for a service or resource shape.
///
/// [Smithy Spec](https://smithy.io/2.0/spec/documentation-traits.html#title-trait)
pub const Title = struct {
    pub const id = SmithyId.of("smithy.api#title");

    pub fn parse(arena: Allocator, reader: *JsonReader) !*const anyopaque {
        return parseString(arena, reader);
    }

    pub fn get(model: *const SmithyModel, shape_id: SmithyId) ?[]const u8 {
        return model.getTrait([]const u8, shape_id, id);
    }
};

fn parseString(arena: Allocator, reader: *JsonReader) !*const anyopaque {
    const value = try arena.create([]const u8);
    value.* = try reader.nextStringAlloc(arena);
    return @ptrCast(value);
}

test "parseString" {
    var arena = std.heap.ArenaAllocator.init(test_alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    var reader = try JsonReader.initFixed(arena_alloc, "\"Foo Bar\"");
    const val: *const []const u8 = @alignCast(@ptrCast(parseString(arena_alloc, &reader) catch |e| {
        reader.deinit();
        return e;
    }));
    reader.deinit();
    try testing.expectEqualStrings("Foo Bar", val.*);
}
